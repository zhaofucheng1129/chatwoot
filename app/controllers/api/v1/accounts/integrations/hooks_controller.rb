class Api::V1::Accounts::Integrations::HooksController < Api::V1::Accounts::BaseController
  before_action :fetch_hook, except: [:create]
  before_action :check_authorization

  def create
    ActiveRecord::Base.transaction do
      @hook = Current.account.hooks.create!(permitted_params.except(:inbox_ids))
      sync_ai_assistant_inboxes
    end
  end

  def update
    ActiveRecord::Base.transaction do
      @hook.update!(permitted_params.slice(:status, :settings))
      sync_ai_assistant_inboxes if permitted_params.key?(:inbox_ids)
    end
  end

  def process_event
    response = @hook.process_event(params[:event])

    # for cases like an invalid event, or when conversation does not have enough messages
    # for a label suggestion, the response is nil
    if response.nil?
      render json: { message: nil }
    elsif response[:error]
      render json: { error: response[:error] }, status: :unprocessable_entity
    else
      render json: { message: response[:message] }
    end
  end

  def destroy
    @hook.destroy!
    head :ok
  end

  private

  def fetch_hook
    @hook = Current.account.hooks.find(params[:id])
  end

  def check_authorization
    authorize(:hook)
  end

  # ai_assistant 助理通过 inbox_ids 关联多个收件箱(增量同步中间表),
  # 其它 inbox 型集成仍用单个 inbox_id(由 permitted_params 直接写入)
  def sync_ai_assistant_inboxes
    return unless @hook.app_id == 'ai_assistant'

    ids = Array(permitted_params[:inbox_ids]).map(&:to_i).uniq.reject(&:zero?)
    if ids.empty?
      @hook.errors.add(:base, I18n.t('errors.ai_assistant.inbox_required'))
      raise ActiveRecord::RecordInvalid, @hook
    end

    @hook.ai_assistant_inboxes.where.not(inbox_id: ids).destroy_all
    existing = @hook.ai_assistant_inboxes.pluck(:inbox_id)
    (ids - existing).each { |inbox_id| @hook.ai_assistant_inboxes.create!(inbox_id: inbox_id) }
  end

  def permitted_params
    params.require(:hook).permit(:app_id, :inbox_id, :status, settings: {}, inbox_ids: [])
  end
end
