# Detects an incoming message's language and stores it in content_attributes,
# so the dashboard can decide whether to offer a translate action.
class Messages::DetectLanguageJob < ApplicationJob
  queue_as :low

  def perform(message_id)
    message = Message.find_by(id: message_id)
    return if message.blank? || message.content.blank?
    return if message.detected_language.present?

    code = Messages::LanguageDetectionService.new(text: message.content).perform
    return if code.blank?

    message.detected_language = code
    message.save!
  end
end
