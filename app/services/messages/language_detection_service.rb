# Detects the language of a piece of text locally using CLD3 (no external API).
# Returns an ISO 639-1 code string (e.g. "en", "zh", "ja") or nil when undetermined.
class Messages::LanguageDetectionService
  pattr_initialize [:text!]

  MAX_CHARS = 1000

  def perform
    return if text.blank?

    detector = CLD3::NNetLanguageIdentifier.new(0, MAX_CHARS)
    result = detector.find_language(text.to_s[0, MAX_CHARS])
    return unless result.reliable?

    result.language.to_s
  rescue StandardError
    nil
  end
end
