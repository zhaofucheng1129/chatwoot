# Auto-closes idle customer-service conversations.
#
# Scans open conversations on API-channel inboxes that are assigned to a human
# agent and whose latest customer (incoming) message is older than
# [IDLE_LIMIT]. Such a conversation is resolved and gets a distinct
# "auto-closed after 5 minutes of inactivity" marker (lt_status =
# idle_resolved) so the client can tell it apart from an agent-initiated close.
#
# AI-handled conversations are intentionally out of scope: they are not `open`
# and carry no assignee, so the query never matches them.
class Conversations::IdleAutoResolveJob < ApplicationJob
  queue_as :scheduled_jobs

  # A conversation with no incoming message newer than this is considered idle.
  IDLE_LIMIT = 5.minutes

  def perform
    inbox_ids = Inbox.where(channel_type: 'Channel::Api').pluck(:id)
    return if inbox_ids.empty?

    Conversation.where(inbox_id: inbox_ids, status: :open)
                .where.not(assignee_id: nil)
                .find_each(batch_size: 100) do |conversation|
      auto_resolve(conversation)
    rescue StandardError => e
      Rails.logger.warn(
        "[Conversations::IdleAutoResolveJob] conversation #{conversation.id} " \
        "failed: #{e.class} #{e.message}"
      )
    end
  end

  private

  def auto_resolve(conversation)
    return unless idle?(conversation)

    # Skip the agent-resolved marker in the resolve callback; post the distinct
    # idle-close marker instead, then resolve (which also releases the agent).
    conversation.lt_auto_resolving = true
    conversation.announce_idle_resolved
    conversation.update!(status: :resolved)
  end

  # Idle = the newest non-private incoming (customer) message is older than the
  # limit. No incoming message at all is treated as not-idle (nothing to time
  # against) so a freshly created conversation is never closed prematurely.
  def idle?(conversation)
    last_incoming_at = conversation.messages
                                   .where(message_type: :incoming, private: false)
                                   .maximum(:created_at)
    last_incoming_at.present? && last_incoming_at <= IDLE_LIMIT.ago
  end
end
