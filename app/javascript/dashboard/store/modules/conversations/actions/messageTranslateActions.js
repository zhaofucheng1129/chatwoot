import MessageApi from '../../../../api/inbox/message';
import ConversationApi from '../../../../api/inbox/conversation';
import types from '../../../mutation-types';

export default {
  // Translates arbitrary draft text (the agent's reply) into the customer's
  // language. Returns { content } and does not persist anything.
  async translateDraftText(_, { conversationId, content, targetLanguage }) {
    const { data } = await ConversationApi.translateText({
      conversationId,
      content,
      targetLanguage,
    });
    return data;
  },

  async translateMessage(
    { commit },
    { conversationId, messageId, targetLanguage }
  ) {
    commit(types.SET_MESSAGE_TRANSLATING, messageId);
    try {
      const { data } = await MessageApi.translateMessage(
        conversationId,
        messageId,
        targetLanguage
      );
      return data;
    } finally {
      commit(types.UNSET_MESSAGE_TRANSLATING, messageId);
    }
  },
};
