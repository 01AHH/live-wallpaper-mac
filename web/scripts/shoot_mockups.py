"""Render the feature page's mockups as PNG screenshots.

    python3 web/scripts/shoot_mockups.py            # → docs/screenshots/*.png
    python3 web/scripts/shoot_mockups.py --pages    # also full-page shots of the home and download pages

Serves web/public locally, opens the home page (the features page) in Chrome (Playwright) and
saves every element marked data-shot="<name>" at 2x.
"""
import asyncio, functools, http.server, pathlib, sys, threading
from playwright.async_api import async_playwright

ROOT = pathlib.Path(__file__).resolve().parents[2]
PUBLIC = ROOT / "web" / "public"
OUT = ROOT / "docs" / "screenshots"


def serve():
    class Quiet(http.server.SimpleHTTPRequestHandler):
        def log_message(self, *args): pass
        def translate_path(self, path):   # clean URLs, like Vercel: /gallery → gallery.html
            fs = pathlib.Path(super().translate_path(path))
            html = fs.with_suffix(".html")
            return str(html) if not fs.exists() and html.exists() else str(fs)
    handler = functools.partial(Quiet, directory=str(PUBLIC))
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return f"http://127.0.0.1:{server.server_address[1]}"


async def main():
    base = serve()
    OUT.mkdir(parents=True, exist_ok=True)
    async with async_playwright() as p:
        browser = await p.chromium.launch(channel="chrome", headless=True)
        ctx = await browser.new_context(viewport={"width": 1440, "height": 900}, device_scale_factor=2,
                                        color_scheme="dark")
        page = await ctx.new_page()
        await page.goto(f"{base}/", wait_until="networkidle")
        # Mocks render at their design size for the export.
        await page.add_style_tag(content=".fit > [data-w] { zoom: 1 !important; } .glow-bands::before { animation: none; }")
        # Swap the low-res preview clips for their full-resolution posters.
        await page.evaluate("""() => Promise.all([...document.querySelectorAll('video[poster]')].map(v => {
            const img = new Image();
            img.className = v.className; img.style.cssText = getComputedStyle(v).cssText;
            for (const k of ['position', 'inset', 'top', 'left', 'width', 'height', 'objectFit', 'maxWidth'])
                img.style[k] = getComputedStyle(v)[k];
            img.src = v.poster; v.replaceWith(img);
            return img.decode().catch(() => {});
        }))""")
        await page.wait_for_timeout(1500)
        for el in await page.query_selector_all("[data-shot]"):
            name = await el.get_attribute("data-shot")
            await el.scroll_into_view_if_needed()
            await el.screenshot(path=str(OUT / f"{name}.png"))
            print("saved", (OUT / f"{name}.png").relative_to(ROOT))
        if "--pages" in sys.argv:
            for name, path in (("home", ""), ("download", "download")):
                pg = await ctx.new_page()
                await pg.goto(f"{base}/{path}?preview", wait_until="networkidle")
                await pg.wait_for_timeout(2500)
                await pg.screenshot(path=str(OUT / f"page-{name}.png"), full_page=True)
                print("saved", (OUT / f"page-{name}.png").relative_to(ROOT))
        await browser.close()

asyncio.run(main())
