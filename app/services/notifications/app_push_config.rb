# App 推送通知(经内部通知服务)的配置, 全部来自环境变量, 便于本地/各环境切换.
# host 为空时整个推送链路静默跳过(未配置即视为关闭, 安全).
#
# 本地测试:设 LIONTRIP_NOTIFY_URL 指向本地通知服务, 并按需设 LIONTRIP_NOTIFY_TEST_RECIPIENT
# 覆盖收件人为你自己的 user id(免去走真实登录联系人).生产部署后去掉 TEST_RECIPIENT,
# 收件人自动取会话联系人的 identifier(即 App user id).
class Notifications::AppPushConfig
  def host
    env('LIONTRIP_NOTIFY_URL')
  end

  # 验证阶段:默认沿用订单通知示例(ord_cancelled)的 type/biz_key/来源系统, 仅用于验证
  # 通知链路是否通畅;接入真实客服消息模板后, 改这些默认值或用对应 env 覆盖即可.
  def notification_type
    env('LIONTRIP_NOTIFY_TYPE', 'ord_cancelled')
  end

  def biz_key
    env('LIONTRIP_NOTIFY_BIZ_KEY', 'order-test')
  end

  def source_system
    env('LIONTRIP_NOTIFY_SOURCE_SYSTEM', 'OrderService')
  end

  def service_name
    env('LIONTRIP_NOTIFY_SERVICE_NAME', source_system)
  end

  def route
    env('LIONTRIP_NOTIFY_ROUTE', 'liontravel://page/order/123')
  end

  def send_mode
    env('LIONTRIP_NOTIFY_SEND_MODE', 'sync')
  end

  def language
    env('LIONTRIP_NOTIFY_LANGUAGE', 'en-US')
  end

  # 验证阶段默认带上示例 header;留空对应 env 即可不发该 header.
  def platform
    env('LIONTRIP_NOTIFY_PLATFORM', 'ios')
  end

  def device_id
    env('LIONTRIP_NOTIFY_DEVICE_ID', 'f5b8a653-1ac8-4814-8520-5db7111892dd')
  end

  # 仅本地测试用:覆盖收件人 user id;生产环境不要设.
  def test_recipient
    env('LIONTRIP_NOTIFY_TEST_RECIPIENT')
  end

  private

  def env(key, default = nil)
    ENV.fetch(key, nil).presence || default
  end
end
