"""UI smoke: theme button + home controls."""
from playwright.sync_api import sync_playwright
import sys

BASE = sys.argv[1] if len(sys.argv) > 1 else "http://localhost:5173"


def main():
    with sync_playwright() as p:
        browser = p.chromium.launch(headless=True)
        page = browser.new_page()
        page.goto(BASE)
        page.wait_for_load_state("networkidle")

        theme = page.locator("[data-theme-toggle]")
        theme.wait_for()
        assert theme.count() == 1

        before = page.evaluate("() => document.documentElement.classList.contains('dark')")
        theme.click()
        page.wait_for_timeout(200)
        after = page.evaluate("() => document.documentElement.classList.contains('dark')")
        assert before != after, "theme toggle should flip dark class"

        assert page.locator("#nickname").count() == 1
        assert page.locator("#create-btn").count() == 1

        print("PASS: UI theme button + home controls")
        browser.close()


if __name__ == "__main__":
    main()
