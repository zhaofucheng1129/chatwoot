# == Schema Information
#
# Table name: integrations_hooks
#
#  id           :bigint           not null, primary key
#  access_token :string
#  hook_type    :integer          default("account")
#  settings     :jsonb
#  status       :integer          default("enabled")
#  created_at   :datetime         not null
#  updated_at   :datetime         not null
#  account_id   :integer
#  app_id       :string
#  inbox_id     :integer
#  reference_id :string
#
class Integrations::Hook < ApplicationRecord
  include Reauthorizable

  attr_readonly :app_id, :account_id, :inbox_id, :hook_type
  before_validation :ensure_hook_type
  after_create :trigger_setup_if_crm

  # TODO: Remove guard once encryption keys become mandatory (target 3-4 releases out).
  encrypts :access_token, deterministic: true if Chatwoot.encryption_configured?

  validates :account_id, presence: true
  validates :app_id, presence: true
  # ai_assistant 走 ai_assistant_inboxes 中间表关联多个收件箱, 不再依赖单个 inbox_id;
  # 其它 inbox 型集成(dialogflow 等)仍要求 inbox_id
  validates :inbox_id, presence: true, if: -> { hook_type == 'inbox' && app_id != 'ai_assistant' }
  validate :validate_settings_json_schema
  validate :ensure_feature_enabled
  validate :validate_openai_api_key, if: :validate_openai_api_key?
  validates :app_id, uniqueness: { scope: [:account_id], unless: -> { app.present? && app.params[:allow_multiple_hooks].present? } }

  # TODO: This seems to be only used for slack at the moment
  # We can add a validator when storing the integration settings and toggle this in future
  enum status: { disabled: 0, enabled: 1 }

  belongs_to :account
  belongs_to :inbox, optional: true
  # ai_assistant 知识库文档;hook 删除时级联清理(仅 ai_assistant hook 实际有数据)
  has_many :ai_assistant_documents, class_name: 'AiAssistant::Document', dependent: :destroy_async
  # ai_assistant 助理关联的收件箱(多对多);hook 即「一个助理」, 可服务多个收件箱
  has_many :ai_assistant_inboxes, class_name: 'AiAssistant::Inbox', dependent: :destroy_async
  has_many :inboxes, through: :ai_assistant_inboxes, source: :inbox
  has_secure_token :access_token

  enum hook_type: { account: 0, inbox: 1 }

  scope :account_hooks, -> { where(hook_type: 'account') }
  scope :inbox_hooks, -> { where(hook_type: 'inbox') }

  def app
    @app ||= Integrations::App.find(id: app_id)
  end

  def slack?
    app_id == 'slack'
  end

  def dialogflow?
    app_id == 'dialogflow'
  end

  def openai?
    app_id == 'openai'
  end

  def notion?
    app_id == 'notion'
  end

  def disable
    update(status: 'disabled')
  end

  # 支持 LLM 健康检查的集成,settings 均含 base_url/api_key/model
  LLM_HEALTH_CHECK_APPS = %w[llm_translator ai_assistant].freeze

  def process_event(event)
    # OpenAI integration migrated to Captain::EditorService
    # Other integrations (slack, dialogflow, etc.) handled via HookJob
    return verify_llm_connection if llm_verify_event?(event)

    { error: 'No processor found' }
  end

  def feature_allowed?
    return true if app.blank?

    flag = app.params[:feature_flag]
    return true unless flag

    account.feature_enabled?(flag)
  end

  private

  def llm_verify_event?(event)
    LLM_HEALTH_CHECK_APPS.include?(app_id) && event&.dig('name') == 'verify_connection'
  end

  # Pings the provider with a minimal completion so the settings UI can show
  # whether the provider is reachable. Result goes back as the event message.
  # ai_assistant 配了 embedding_model 时,额外 ping /embeddings 并附加 embedding 字段.
  def verify_llm_connection
    result = Llm::ProviderHealthCheckService.new(settings: settings || {}).perform
    result[:embedding] = Llm::EmbeddingHealthCheckService.new(hook: self).perform if verify_embedding?
    { message: result }
  end

  def verify_embedding?
    app_id == 'ai_assistant' && (settings || {})['embedding_model'].present?
  end

  def ensure_feature_enabled
    errors.add(:feature_flag, 'Feature not enabled') unless feature_allowed?
  end

  def ensure_hook_type
    self.hook_type = app.params[:hook_type] if app.present?
  end

  def validate_settings_json_schema
    return if app.blank? || app.params[:settings_json_schema].blank?

    errors.add(:settings, ': Invalid settings data') unless JSONSchemer.schema(app.params[:settings_json_schema]).valid?(settings)
  end

  # TODO: When adding credential validation for other integrations (dialogflow, dyte, etc.),
  # extract this into an app-level config flag in apps.yml instead of hardcoding app_id checks.
  def validate_openai_api_key?
    openai? && enabled? && (new_record? || openai_api_key_changed? || will_save_change_to_status?)
  end

  def openai_api_key_changed?
    settings_api_key(settings) != settings_api_key(settings_in_database)
  end

  def validate_openai_api_key
    return if Integrations::Openai::KeyValidator.valid?(settings_api_key(settings))

    errors.add(:base, I18n.t('errors.openai.invalid_api_key'))
  end

  def settings_api_key(value)
    value&.dig('api_key') || value&.dig(:api_key)
  end

  def trigger_setup_if_crm
    # we need setup services to create data prerequisite to functioning of the integration
    # in case of Leadsquared, we need to create a custom activity type for capturing conversations and transcripts
    # https://apidocs.leadsquared.com/create-new-activity-type-api/
    return unless crm_integration?

    ::Crm::SetupJob.perform_later(id)
  end

  def crm_integration?
    %w[leadsquared].include?(app_id)
  end
end
