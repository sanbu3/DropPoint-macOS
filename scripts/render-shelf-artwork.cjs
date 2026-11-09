// Development only: rasterize the ORIGINAL SVG timelines, including path morphs.
// Usage: NODE_PATH=/path/to/node_modules node scripts/render-shelf-artwork.cjs
const { chromium } = require('playwright');
const fs = require('node:fs');
const path = require('node:path');
(async () => {
  const browser = await chromium.launch({headless:true});
  try {
    for (const [name, size, duration] of [['Cat_in_Box',224,2.97], ['Empty Box',304,4.037]]) {
      const page = await browser.newPage({viewport:{width:size,height:size},deviceScaleFactor:1});
      const svg = fs.readFileSync(path.join('Resources',name+'.svg'),'utf8');
      await page.setContent(`<style>html,body{margin:0;width:100%;height:100%;overflow:hidden;background:transparent}svg{display:block;width:100%;height:100%}</style>${svg}`);
      await page.evaluate(()=>document.querySelector('svg').pauseAnimations());
      const count = Math.ceil(duration*30);
      const dir = path.join('.build','artwork-frames',name);
      fs.mkdirSync(dir,{recursive:true});
      for(let i=0;i<count;i++) {
        await page.evaluate(t=>document.querySelector('svg').setCurrentTime(t),i*duration/count);
        await page.screenshot({path:path.join(dir,`${String(i).padStart(3,'0')}.png`),omitBackground:true});
      }
      await page.close();
      console.log(name, count, 'frames', duration, 'seconds');
    }
  } finally {await browser.close();}
})().catch(e=>{console.error(e);process.exit(1)});
