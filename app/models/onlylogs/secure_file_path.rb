# frozen_string_literal: true

module Onlylogs
  class SecureFilePath
    class SecurityError < StandardError; end

    def self.encrypt(file_path)
      encryptor = ActiveSupport::MessageEncryptor.new(encryption_key)
      encrypted = encryptor.encrypt_and_sign(file_path.to_s)
      Base64.urlsafe_encode64(encrypted).tr("=", "")
    rescue => e
      Rails.logger.error "Onlylogs: Encryption failed for #{file_path}: #{e.message}"
      raise SecurityError, "Encryption failed"
    end

    def self.decrypt(encrypted_path)
      decoded = Base64.urlsafe_decode64(encrypted_path)
      encryptor = ActiveSupport::MessageEncryptor.new(encryption_key)
      encryptor.decrypt_and_verify(decoded)
    rescue => e
      Rails.logger.error "Onlylogs: Decryption failed: #{e.message}"
      raise SecurityError, "Invalid encrypted file path"
    end

    private

    def self.encryption_key
      Rails.application.secret_key_base[0..31]
    end
  end
end
