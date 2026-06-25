class CreateAiAssistantInboxes < ActiveRecord::Migration[7.1]
  def up
    create_table :ai_assistant_inboxes do |t|
      t.bigint :hook_id, null: false
      t.bigint :inbox_id, null: false

      t.timestamps
    end

    add_index :ai_assistant_inboxes, :hook_id
    # 一个收件箱只能归属一个 AI 助理, 避免触发时出现歧义
    add_index :ai_assistant_inboxes, :inbox_id, unique: true
    add_index :ai_assistant_inboxes, %i[hook_id inbox_id], unique: true

    # backfill: 为每个现有 ai_assistant hook 按其 inbox_id 建一条关联,
    # 迁移后既有助理行为保持不变(各自仍服务原来的单个收件箱)
    execute(<<~SQL.squish)
      INSERT INTO ai_assistant_inboxes (hook_id, inbox_id, created_at, updated_at)
      SELECT id, inbox_id, NOW(), NOW()
      FROM integrations_hooks
      WHERE app_id = 'ai_assistant' AND inbox_id IS NOT NULL
    SQL
  end

  def down
    drop_table :ai_assistant_inboxes
  end
end
