/* global axios */

import ApiClient from './ApiClient';

class AiAssistantDocumentsAPI extends ApiClient {
  constructor() {
    super('ai_assistant/documents', { accountScoped: true });
  }

  list(hookId) {
    return axios.get(this.url, { params: { hook_id: hookId } });
  }

  create({ hookId, title, content }) {
    return axios.post(this.url, {
      hook_id: hookId,
      title,
      content,
    });
  }
}

export default new AiAssistantDocumentsAPI();
