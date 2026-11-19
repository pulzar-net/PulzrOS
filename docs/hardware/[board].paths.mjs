// One page per boards/<id>/, generated from its board.conf (../.vitepress/boards.mjs).
import { boards, boardPage } from '../.vitepress/boards.mjs';

export default {
  watch: ['../../boards/**/board.conf', '../../boards/common/*.conf'],
  paths() {
    return boards().map((b) => ({
      params: { board: b.id, title: b.name },
      content: boardPage(b),
    }));
  },
};
