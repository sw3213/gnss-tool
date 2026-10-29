// Protomaps 공식 스타일(레이어 목록)을 JSON으로 뽑는다. GitHub Actions(style.yml)에서 실행.
// 결과는 앱의 assets/map/style-light.json 으로 들어가고, 앱이 소스·글꼴 이름만 바꿔 씀.
import { writeFileSync } from 'node:fs';
import { layers, namedFlavor } from '@protomaps/basemaps';

const out = layers('protomaps', namedFlavor('light'), { lang: 'ko' });
writeFileSync('style-light.json', JSON.stringify(out));

// 앱에 넣어야 할 글꼴 이름 목록
const fonts = new Set();
for (const l of out) for (const f of l.layout?.['text-font'] ?? []) fonts.add(f);
console.log('layers:', out.length, 'fonts:', [...fonts].join(' | '));
