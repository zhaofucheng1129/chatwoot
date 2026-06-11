# AI 客服助理知识库文档管理 API.仅管理员可访问;文档按 ai_assistant hook 归属.
class Api::V1::Accounts::AiAssistant::DocumentsController < Api::V1::Accounts::BaseController
  before_action :check_admin_authorization?
  before_action :fetch_hook, only: [:index, :create]
  before_action :fetch_document, only: [:destroy]

  CONTENT_PREVIEW_LENGTH = 200

  def index
    @documents = @hook.ai_assistant_documents.order(created_at: :desc)
    render json: @documents.map { |document| serialize(document) }
  end

  def create
    @document = @hook.ai_assistant_documents.create!(
      account: Current.account,
      title: permitted_params[:title],
      content: permitted_params[:content]
    )
    render json: serialize(@document)
  end

  def destroy
    @document.destroy!
    head :no_content
  end

  private

  # 校验 hook 属于当前 account 且为 ai_assistant 集成
  def fetch_hook
    @hook = Current.account.hooks.where(app_id: 'ai_assistant').find(permitted_params[:hook_id])
  end

  def fetch_document
    @document = AiAssistant::Document.where(account: Current.account).find(params[:id])
  end

  def serialize(document)
    {
      id: document.id,
      hook_id: document.hook_id,
      title: document.title,
      status: document.status,
      content_preview: document.content.to_s[0, CONTENT_PREVIEW_LENGTH],
      created_at: document.created_at.to_i
    }
  end

  def permitted_params
    params.permit(:id, :hook_id, :title, :content)
  end
end
