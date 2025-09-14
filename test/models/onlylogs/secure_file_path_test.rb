# frozen_string_literal: true

require "test_helper"

module Onlylogs
  class SecureFilePathTest < ActiveSupport::TestCase
    test "encrypts and decrypts file paths successfully" do
      test_path = "/path/to/test.log"
      encrypted = SecureFilePath.encrypt(test_path)

      assert_not_nil encrypted
      assert_not_equal test_path, encrypted

      decrypted = SecureFilePath.decrypt(encrypted)
      assert_equal test_path, decrypted
    end

    test "raises SecurityError when decrypting invalid encrypted path" do
      assert_raises(SecureFilePath::SecurityError) do
        SecureFilePath.decrypt("invalid_encrypted_path")
      end
    end

    test "handles Pathname objects" do
      pathname = Pathname.new("/path/to/test.log")
      encrypted = SecureFilePath.encrypt(pathname)
      decrypted = SecureFilePath.decrypt(encrypted)

      assert_equal "/path/to/test.log", decrypted
    end

    test "encryption produces different results for same input due to random IV" do
      test_path = "/path/to/test.log"
      encrypted1 = SecureFilePath.encrypt(test_path)
      encrypted2 = SecureFilePath.encrypt(test_path)

      # MessageEncryptor produces different output for same input (due to random IV)
      assert_not_equal encrypted1, encrypted2

      # But both should decrypt to the same value
      assert_equal SecureFilePath.decrypt(encrypted1), SecureFilePath.decrypt(encrypted2)
    end

    test "encrypted paths are URL-safe" do
      test_path = "/path/to/test.log"
      encrypted = SecureFilePath.encrypt(test_path)

      # URL-safe base64 should not contain +, /, or = characters
      refute_match(/[+\/=]/, encrypted)

      # Should be able to decrypt it
      decrypted = SecureFilePath.decrypt(encrypted)
      assert_equal test_path, decrypted
    end
  end
end
