# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Llm::OrderDetailService do
  let(:conversation) { create(:conversation) }

  def http_response(success:, body: '', code: 200)
    instance_double(
      HTTParty::Response, success?: success, body: body, code: code
    )
  end

  def order_message(order_no)
    create(
      :message,
      conversation: conversation,
      account: conversation.account,
      inbox: conversation.inbox,
      message_type: :incoming,
      content: "Tokyo 5 days\n$1299\n##{order_no}"
    )
  end

  describe '#perform' do
    context 'when an order-context message carries an order number' do
      before { order_message('ORD-123') }

      it 'fetches that order and injects its detail as JSON' do
        allow(HTTParty).to receive(:get)
          .with(a_string_ending_with('/orders/ORD-123'), anything)
          .and_return(http_response(success: true, body: '{"status":"paid"}'))

        result = described_class.new(conversation: conversation).perform

        expect(result).to include('ORD-123')
        expect(result).to include('{"status":"paid"}')
      end
    end

    context 'when several order-context messages exist' do
      it 'uses the most recent order number' do
        order_message('ORD-OLD')
        order_message('ORD-NEW')

        allow(HTTParty).to receive(:get).and_return(
          http_response(success: true, body: '{"ok":true}')
        )

        described_class.new(conversation: conversation).perform

        expect(HTTParty).to have_received(:get)
          .with(a_string_ending_with('/orders/ORD-NEW'), anything)
      end
    end

    context 'when no message carries an order number' do
      before do
        conversation.update!(custom_attributes: { 'order_id' => 'ORD-ATTR' })
        create(
          :message,
          conversation: conversation,
          account: conversation.account,
          inbox: conversation.inbox,
          message_type: :incoming,
          content: 'just a question without an order'
        )
      end

      it 'falls back to the conversation custom_attributes order_id' do
        allow(HTTParty).to receive(:get).and_return(
          http_response(success: true, body: '{"ok":true}')
        )

        described_class.new(conversation: conversation).perform

        expect(HTTParty).to have_received(:get)
          .with(a_string_ending_with('/orders/ORD-ATTR'), anything)
      end
    end

    context 'when there is no order number anywhere' do
      it 'returns nil without calling the API' do
        allow(HTTParty).to receive(:get)

        expect(described_class.new(conversation: conversation).perform).to be_nil
        expect(HTTParty).not_to have_received(:get)
      end
    end

    context 'when the order API returns a non-2xx response' do
      before { order_message('ORD-500') }

      it 'returns nil and degrades' do
        allow(HTTParty).to receive(:get).and_return(
          http_response(success: false, code: 500, body: 'oops')
        )

        expect(described_class.new(conversation: conversation).perform).to be_nil
      end
    end

    context 'when the HTTP call raises' do
      before { order_message('ORD-ERR') }

      it 'rescues and returns nil' do
        allow(HTTParty).to receive(:get).and_raise(StandardError.new('boom'))

        expect(described_class.new(conversation: conversation).perform).to be_nil
      end
    end

    context 'when LIONTRIP_ORDER_API_URL is set' do
      before { order_message('ORD-ENV') }

      it 'targets the configured base url' do
        allow(ENV).to receive(:[]).and_call_original
        allow(ENV).to receive(:[]).with('LIONTRIP_ORDER_API_URL')
                                  .and_return('http://orders.internal')
        allow(HTTParty).to receive(:get).and_return(
          http_response(success: true, body: '{}')
        )

        described_class.new(conversation: conversation).perform

        expect(HTTParty).to have_received(:get).with(
          'http://orders.internal/order/api/v1/internalservice/orders/ORD-ENV',
          anything
        )
      end
    end
  end
end
