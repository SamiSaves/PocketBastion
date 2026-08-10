// @ts-check
import { defineConfig } from 'astro/config';

export default defineConfig({
  // Static, and it stays static: the box serves files, it does not run Astro.
  // An SSR adapter would put a permanent Node process on a 4 GB Pi.
  output: 'static',
  build: {
    // login.html, not login/index.html — pbweb serves files, not directories.
    format: 'file',
    // Everything the browser needs in the HTML: the built output is inlined
    // into the Ignition config, so each extra asset file is another blob there.
    inlineStylesheets: 'always',
  },
});
