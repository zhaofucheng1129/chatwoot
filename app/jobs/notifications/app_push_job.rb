# 服务端向客户发出消息时, 调用内部通知服务给客户的 App 推送通知.
# 由 AppNotificationListener 在 message.created 后入队(仅人工客服回复).
#
# 幂等:idempotency_key 固定为 cs-msg-<message_id>, 通知服务据此去重, Job 重试不会重复推.
# 失败:记日志, 不抛出(通知非关键路径, 不影响发消息主流程).
class Notifications::AppPushJob < ApplicationJob
  queue_as :medium

  NOTIFY_PATH = '/api/v1/internal/notifications/send'.freeze

  def perform(message_id)
    message = Message.find_by(id: message_id)
    return if message.blank?

    Rails.logger.info("[Notifications::AppPushJob] start message=#{message_id}")
    config = Notifications::AppPushConfig.new
    if config.host.blank?
      Rails.logger.warn("[Notifications::AppPushJob] skip message=#{message_id}: LIONTRIP_NOTIFY_URL not set")
      return
    end

    recipient = config.test_recipient.presence || message.conversation.contact&.identifier
    if recipient.blank?
      Rails.logger.warn("[Notifications::AppPushJob] skip message=#{message_id}: no recipient (no contact.identifier / TEST_RECIPIENT)")
      return
    end

    deliver(config, message, recipient.to_s)
  end

  private

  def deliver(config, message, recipient)
    response = HTTParty.post(
      "#{config.host.chomp('/')}#{NOTIFY_PATH}",
      headers: headers(config),
      body: body(config, message, recipient).to_json,
      open_timeout: 10,
      # sync 模式会等通知服务把所有设备下发完才返回(实测十几个设备约 5s), 留足读超时
      read_timeout: 30
    )
    if response.success?
      Rails.logger.info("[Notifications::AppPushJob] sent message=#{message.id} -> #{recipient} status=#{response.code}")
    else
      Rails.logger.error("[Notifications::AppPushJob] non-2xx for message #{message.id}: #{response.code} #{response.body}")
    end
  rescue StandardError => e
    Rails.logger.error("[Notifications::AppPushJob] failed for message #{message.id}: #{e.class} #{e.message}")
  end

  def headers(config)
    headers = {
      'accept' => 'application/json',
      'Content-Type' => 'application/json',
      'X-Request-ID' => SecureRandom.uuid,
      'X-Language' => config.language,
      'X-Service-Name' => config.service_name,
      'X-Send-Mode' => config.send_mode
    }
    headers['X-Platform'] = config.platform if config.platform.present?
    headers['X-Device-Id'] = config.device_id if config.device_id.present?
    headers
  end

  def body(config, message, recipient)
    {
      biz_key: config.biz_key,
      idempotency_key: SecureRandom.uuid,
      recipient_user_ids: [recipient],
      source_system: config.source_system,
      type: config.notification_type,
      variables: variables(config, message)
    }
  end

  # 验证阶段:沿用订单通知示例(ord_cancelled)的固定变量, 仅验证链路通畅;
  # 接入真实客服消息模板后, 这里改为按 message 取值(正文/发送者/会话路由等).
  def variables(config, _message)
    {
      order_no: '123',
      route: config.route,
      image_url: 'test url'
    }
  end
end
