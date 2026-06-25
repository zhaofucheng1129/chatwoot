json.id resource.id
json.app_id resource.app_id
json.status resource.enabled?
json.inbox resource.inbox&.slice(:id, :name)
# ai_assistant 助理关联的多个收件箱;其它集成此数组为空, 前端仍读单个 inbox
json.inboxes do
  json.array! resource.inboxes do |inbox|
    json.id inbox.id
    json.name inbox.name
  end
end
json.account_id resource.account_id
json.hook_type resource.hook_type

json.settings resource.settings if Current.account_user&.administrator?
json.reference_id resource.reference_id if Current.account_user&.administrator?
