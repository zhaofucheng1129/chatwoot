# 服务端向客户发出消息时, 同步给客户的 App 推送通知(经内部通知服务).
#
# 仅人工客服的回复触发:
# - outgoing 且非私有备注
# - sender 为坐席(User);AI 自动回复与状态标记消息的 sender 是 AgentBot, 据此排除
# - 额外排除带 lt_status 的状态标记消息(连接中/已接入/已解决)
# - 需有正文(纯附件消息暂不推)
# - 客户须为已登录 App 用户(contact.identifier 即 App user id, 作为收件人)
class AppNotificationListener < BaseListener
  def message_created(event)
    message, = extract_message_and_account(event)
    return unless pushable?(message)

    Rails.logger.info("[AppNotificationListener] enqueue AppPushJob message=#{message.id}")
    Notifications::AppPushJob.perform_later(message.id)
  end

  private

  def pushable?(message)
    message.outgoing? &&
      !message.private? &&
      message.sender_type == 'User' &&
      message.content_attributes['lt_status'].blank? &&
      message.content.present? &&
      recipient_present?(message)
  end

  # 能否解析出收件人:本地测试配了 TEST_RECIPIENT 即可(免去真实登录联系人);
  # 否则需联系人有 identifier(= App user id).与 Job 的收件人解析保持一致.
  def recipient_present?(message)
    Notifications::AppPushConfig.new.test_recipient.present? ||
      message.conversation.contact&.identifier.present?
  end
end
