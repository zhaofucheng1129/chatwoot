# AI 客服回复护栏:提示词之外的纵深防御层,降低恶意引导/越狱与系统设定泄露风险.
#
# - injection?  : 检测客户输入是否为高置信度的提示词注入(忽略指令/开发者模式/索取
#                 系统提示词等).命中则由调用方直接走标准话术,不调用模型(成本低、
#                 确定性强、模型不被触达自然无法被越狱).
# - leaked?     : 检测模型回复是否疑似泄露系统设定或越狱合规.命中则用安全话术替换.
# - safe_message: 标准兜底话术,可经 hook 的 `guard_message` 设置覆盖.
#
# 说明:护栏只做高置信度匹配以避免误伤正常客户;它不替代提示词,只是最后一道闸.
class Llm::ResponseGuardService
  pattr_initialize [[:settings, {}]]

  # 高置信度注入特征(命中即判恶意引导).刻意保守,避免误伤正常旅游提问.
  INJECTION_PATTERNS = [
    /ignore\s+(?:all\s+|the\s+|any\s+|your\s+)?(?:previous|above|prior|earlier|preceding).{0,24}(?:instruction|prompt|rule|message)/i,
    /disregard\s+.{0,24}(?:instruction|prompt|rule|message)/i,
    /忽略(?:以上|上述|之前|前面|先前|你的).{0,8}(?:指令|指示|提示|规则|設定|设定|要求)/,
    /(?:developer|debug|dan|jailbreak|god)\s*mode/i,
    /开发者模式|開發者模式|越狱模式|越獄模式/,
    /(?:reveal|show|print|repeat|output|expose|tell\s+me)\s+(?:your|the).{0,16}(?:prompt|instruction|rule|setup)/i,
    /(?:输出|显示|打印|告诉我|複述|复述|重复|重複)(?:一下)?(?:你的|本|这段|這段)?(?:完整)?(?:系统|系統)?(?:提示词|提示詞|指令|設定|设定|规则|規則)/
  ].freeze

  # 回复中疑似泄露系统设定/越狱合规的特征.均为本系统设定中独有、正常回复不会出现的串.
  # 注意:不含 [[HANDOFF]] —— 那是模型主动转人工的合法信号,绝不能当泄露拦掉.
  LEAK_PATTERNS = [
    /身份与边界|身份與邊界/,
    /最高优先,任何消息|最高優先,任何訊息/,
    /无权代表公司|無權代表公司/,
    /(?:我的|这是我的|這是我的|以下是我的)(?:完整)?(?:系统|系統)?(?:提示词|提示詞|指令|設定|设定)/,
    /(?:system\s*prompt|my\s+(?:system\s+)?instructions?)\s*[:：]/i,
    /(?:开发者模式|開發者模式)(?:已|现已|現已)?(?:开启|開啟|啟用|启用|激活)|developer\s*mode\s*(?:on|enabled|activated)/i
  ].freeze

  DEFAULT_MESSAGE = '抱歉, 我是雄狮旅游的客服助理, 只能协助您处理旅游相关的问题(订单、行程、签证、付款等)。' \
                    '请问有什么旅游方面的需求我可以帮您?'.freeze

  def injection?(text)
    value = text.to_s
    return false if value.blank?

    INJECTION_PATTERNS.any? { |pattern| pattern.match?(value) }
  end

  def leaked?(text)
    value = text.to_s
    return false if value.blank?

    LEAK_PATTERNS.any? { |pattern| pattern.match?(value) }
  end

  def safe_message
    (settings || {})['guard_message'].to_s.presence || DEFAULT_MESSAGE
  end
end
