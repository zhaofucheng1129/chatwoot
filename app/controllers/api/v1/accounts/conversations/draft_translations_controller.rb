# Translates arbitrary draft text (the agent's reply) into the customer's
# language. Unlike messages#translate this works on text that is not yet a
# persisted message. Conversation scoping handles authorization.
class Api::V1::Accounts::Conversations::DraftTranslationsController < Api::V1::Accounts::Conversations::BaseController
  def create
    translated = Llm::TranslationService.new(
      content: params[:content],
      target_language: params[:target_language],
      account: @conversation.account
    ).perform

    render json: { content: translated }
  end
end
