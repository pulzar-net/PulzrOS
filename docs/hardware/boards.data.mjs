// The board table on the Hardware page, from the same facts as each board's page.
import { boards, family, radio, statusText, FEATURES } from '../.vitepress/boards.mjs';

export default {
  watch: ['../../boards/**/board.conf', '../../boards/common/*.conf'],
  load() {
    return boards().map((b) => ({
      id: b.id,
      name: b.name,
      family: family(b),
      built: b.status === 'supported',
      status: statusText(b),
      radio: radio(b),
      features: b.features.map((f) => FEATURES[f] ?? f).join(', '),
    }));
  },
};
