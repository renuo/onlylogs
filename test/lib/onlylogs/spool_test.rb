# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "fileutils"

module Onlylogs
  class SpoolTest < ActiveSupport::TestCase
    setup do
      @root = ::Dir.mktmpdir
      @spool = Onlylogs::Spool.new(dir: @root)
    end

    teardown do
      ::Dir.glob(::File.join(@root, "*")).each { |path| ::File.chmod(0o755, path) if ::File.directory?(path) }
      ::FileUtils.remove_entry(@root) if ::File.directory?(@root)
    end

    test "writes a batch and replays it, deleting the file once delivered" do
      @spool.write("hello\nworld")

      replayed = []
      @spool.replay do |body|
        replayed << body
        true
      end

      assert_equal ["hello\nworld"], replayed
      assert @spool.empty?, "the spool should be empty after a successful replay"
      assert_empty batches(@spool.dir)
    end

    test "ignores blank batches" do
      @spool.write(nil)
      @spool.write("")

      assert @spool.empty?
    end

    test "keeps the batch on disk when delivery fails, and delivers it on a later replay" do
      @spool.write("keep me")

      @spool.replay { |_body| false }
      refute @spool.empty?, "a failed delivery must not delete the spooled batch"

      delivered = []
      @spool.replay do |body|
        delivered << body
        true
      end
      assert_equal ["keep me"], delivered
      assert @spool.empty?
    end

    test "replays oldest-first and stops at the first failure" do
      @spool.write("one")
      @spool.write("two")
      @spool.write("three")

      seen = []
      @spool.replay do |body|
        seen << body
        body != "two"
      end
      assert_equal ["one", "two"], seen

      remaining = []
      @spool.replay do |body|
        remaining << body
        true
      end
      assert_equal ["two", "three"], remaining
    end

    test "replays only the oldest batches when a limit is given" do
      @spool.write("one")
      @spool.write("two")

      seen = []
      @spool.replay(limit: 1) do |body|
        seen << body
        true
      end
      assert_equal ["one"], seen
      refute @spool.empty?

      @spool.replay(limit: 1) do |body|
        seen << body
        true
      end
      assert_equal ["one", "two"], seen
      assert @spool.empty?
    end

    test "rolls the oldest batches off when the byte cap is exceeded" do
      spool = Onlylogs::Spool.new(dir: @root, max_bytes: 20)

      spool.write("a" * 8)
      spool.write("b" * 8)
      spool.write("c" * 8) # 24 > 20 -> evict the oldest ("a")

      assert_equal ["b" * 8, "c" * 8], drain(spool)
      assert_equal 0, batches(spool.dir).size
    ensure
      spool&.close
    end

    # A batch this process delivered but cannot delete (wrong owner, read-only volume) must not be
    # replayed again and again: it is forgotten with one warning and sent once more after a restart.
    test "warns once and forgets a delivered batch it cannot delete" do
      skip "root can delete anything" if Process.uid.zero?
      @spool.write("stuck")
      ::File.chmod(0o555, @spool.dir)

      delivered = []
      warnings = capture_stderr { 3.times { @spool.replay { |body| delivered << body } } }

      assert_equal ["stuck"], delivered
      assert @spool.empty?
      assert_equal 1, warnings.scan("cannot delete").size
      assert_equal 1, batches(@spool.dir).size
    end

    test "skips a batch it cannot read" do
      skip "root can read anything" if Process.uid.zero?
      @spool.write("unreadable")
      @spool.write("fine")
      ::File.chmod(0o000, batches(@spool.dir).min)

      delivered = []
      warnings = capture_stderr { @spool.replay { |body| delivered << body } }

      assert_equal ["fine"], delivered
      assert @spool.empty?
      assert_equal 1, warnings.scan("cannot read").size
    end

    test "adopts the batches a dead instance left behind and removes its directory" do
      @spool.write("orphaned one")
      @spool.write("orphaned two")
      dead_dir = @spool.dir
      @spool.close

      heir = Onlylogs::Spool.new(dir: @root)
      heir.adopt_orphans

      assert_equal ["orphaned one", "orphaned two"], drain(heir)
      refute ::File.directory?(dead_dir), "the adopted directory should be removed"
    ensure
      heir&.close
    end

    test "does not adopt the batches of a live instance" do
      @spool.write("mine")

      other = Onlylogs::Spool.new(dir: @root)
      other.adopt_orphans

      assert other.empty?
      assert_equal ["mine"], drain(@spool)
    ensure
      other&.close
    end

    # flock is held per open file description, so two instances in one process contend for real.
    test "two instances racing to adopt the same dead one deliver each batch once" do
      100.times { |i| @spool.write("batch #{i}") }
      @spool.close

      heirs = Array.new(2) { Onlylogs::Spool.new(dir: @root) }
      threads = heirs.map { |heir| Thread.new { heir.adopt_orphans } }
      threads.each(&:join)

      delivered = heirs.flat_map { |heir| drain(heir) }
      assert_equal 100, delivered.size
      assert_equal 100, delivered.uniq.size
    ensure
      heirs&.each(&:close)
    end

    test "close removes its directory when empty and keeps it when batches remain" do
      empty = Onlylogs::Spool.new(dir: @root)
      empty.close
      refute ::File.directory?(empty.dir)

      full = Onlylogs::Spool.new(dir: @root)
      full.write("still here")
      full.close
      assert_equal 1, batches(full.dir).size
    end

    test "leaves an orphan it cannot move for a later start, with one warning" do
      skip "root can rename anything" if Process.uid.zero?
      @spool.write("immovable")
      dead_dir = @spool.dir
      @spool.close
      ::File.chmod(0o555, dead_dir)

      heir = Onlylogs::Spool.new(dir: @root)
      warnings = capture_stderr { heir.adopt_orphans }

      assert heir.empty?
      assert_equal 1, warnings.scan("cannot adopt").size
      assert_equal 1, batches(dead_dir).size
      assert Onlylogs::Spool.new(dir: @root).tap(&:close), "the orphan's lock must be released again"
    ensure
      heir&.close
    end

    test "adopts batches left at the top level by the shared-directory layout" do
      ::File.binwrite(::File.join(@root, "deadbeef-000000001.batch"), "legacy one")
      ::File.binwrite(::File.join(@root, "deadbeef-000000002.batch.sending"), "legacy two")

      @spool.adopt_orphans

      assert_equal ["legacy one", "legacy two"], drain(@spool).sort
      assert_empty ::Dir.glob(::File.join(@root, "*.batch*"))
    end

    # A backlog is handed out a chunk at a time so that every live worker takes a share of it.
    test "adopts a big backlog in chunks and removes the directory with the last one" do
      250.times { |i| @spool.write("batch #{i}") }
      dead_dir = @spool.dir
      @spool.close

      heir = Onlylogs::Spool.new(dir: @root)
      taken = 3.times.map do
        heir.adopt_orphans
        drain(heir).size
      end

      assert_equal [100, 100, 50], taken
      refute ::File.directory?(dead_dir)
    ensure
      heir&.close
    end

    test "two live instances share a dead one's backlog" do
      250.times { |i| @spool.write("batch #{i}") }
      @spool.close
      heirs = Array.new(2) { Onlylogs::Spool.new(dir: @root) }

      delivered = []
      until heirs.all?(&:empty?) && ::Dir.glob(::File.join(@root, "*", "*.batch")).empty?
        heirs.each do |heir|
          heir.adopt_orphans if heir.empty?
          delivered << [heir, drain(heir)]
        end
      end

      per_heir = delivered.group_by(&:first).transform_values { |pairs| pairs.sum { |_, bodies| bodies.size } }
      assert_equal 250, per_heir.values.sum
      assert per_heir.values.all?(&:positive?), "both instances should have delivered some: #{per_heir.values}"
      assert_equal 250, delivered.flat_map(&:last).uniq.size
    ensure
      heirs&.each(&:close)
    end

    test "adopts the oldest batches first" do
      @spool.write("newer")
      @spool.write("older")
      _, older = batches(@spool.dir).sort
      ::File.utime(Time.now - 60, Time.now - 60, older)
      @spool.close

      heir = Onlylogs::Spool.new(dir: @root)
      heir.adopt_orphans

      assert_equal ["older", "newer"], drain(heir)
    ensure
      heir&.close
    end

    # A crash between binwrite and rename leaves a .tmp behind: it must never reach the drain.
    test "does not ship a torn batch a dead instance was writing" do
      @spool.write("complete")
      dead_dir = @spool.dir
      @spool.close
      ::File.binwrite(::File.join(dead_dir, "000000002.batch.tmp"), "half a ba")

      heir = Onlylogs::Spool.new(dir: @root)
      heir.adopt_orphans

      assert_equal ["complete"], drain(heir)
      refute ::File.directory?(dead_dir), "the torn file should go with the directory"
    ensure
      heir&.close
    end

    test "keeps adopted batches under its own byte cap" do
      5.times { |i| @spool.write(i.to_s * 8) }
      @spool.close

      heir = Onlylogs::Spool.new(dir: @root, max_bytes: 16)
      heir.adopt_orphans

      assert_equal ["3" * 8, "4" * 8], drain(heir)
      assert_empty ::Dir.glob(::File.join(@root, "*", "*.batch"))
    ensure
      heir&.close
    end

    test "warns instead of raising when a batch cannot be written" do
      ::FileUtils.rm_rf(@spool.dir)

      warnings = capture_stderr { @spool.write("lost") }

      assert @spool.empty?
      assert_includes warnings, "write error"
    end

    test "refuses to start in a directory it cannot create" do
      file = ::File.join(@root, "not-a-dir")
      ::File.write(file, "")

      assert_raises(SystemCallError) { Onlylogs::Spool.new(dir: file) }
    end

    test "two instances racing for the same top-level batches take each once" do
      200.times { |i| ::File.binwrite(::File.join(@root, "old-#{format("%09d", i)}.batch"), "legacy #{i}") }
      other = Onlylogs::Spool.new(dir: @root)

      [@spool, other].map { |spool| Thread.new { 2.times { spool.adopt_orphans } } }.each(&:join)

      delivered = drain(@spool) + drain(other)
      assert_equal 200, delivered.size
      assert_equal 200, delivered.uniq.size
    ensure
      other&.close
    end

    # Whoever can write the spool root could point a symlink at any file the app can read.
    test "does not follow symlinks planted in the spool root" do
      victim = ::Dir.mktmpdir
      ::File.write(::File.join(victim, "lock"), "")
      ::File.write(::File.join(victim, "secret.batch"), "SECRET")
      ::File.symlink(victim, ::File.join(@root, "evil-dir"))
      ::File.symlink(::File.join(victim, "secret.batch"), ::File.join(@root, "evil-000000001.batch"))

      @spool.adopt_orphans

      assert @spool.empty?, "nothing behind a symlink should be adopted"
      assert ::File.exist?(::File.join(victim, "secret.batch"))
    ensure
      ::FileUtils.remove_entry(victim) if victim && ::File.directory?(victim)
    end

    private

    def batches(dir)
      ::Dir.glob(::File.join(dir, "*.batch"))
    end

    def drain(spool)
      [].tap do |bodies|
        spool.replay do |body|
          bodies << body
          true
        end
      end
    end

    def capture_stderr
      original = $stderr
      $stderr = StringIO.new
      yield
      $stderr.string
    ensure
      $stderr = original
    end
  end
end
