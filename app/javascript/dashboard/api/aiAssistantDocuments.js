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

  show(id) {
    return axios.get(`${this.url}/${id}`);
  }

  update({ id, title, content }) {
    return axios.patch(`${this.url}/${id}`, { title, content });
  }

  reprocess(hookId) {
    return axios.post(`${this.url}/reprocess`, { hook_id: hookId });
  }
}

export default new AiAssistantDocumentsAPI();
