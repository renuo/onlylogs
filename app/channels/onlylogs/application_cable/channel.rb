# frozen_string_literal: true

module Onlylogs
  module ApplicationCable
    class Channel < ActionCable::Channel::Base
      def subscribed
        stream_from "onlylogs:stream"
      end
    end
  end
end
