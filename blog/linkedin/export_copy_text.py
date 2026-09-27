"""Export LinkedIn HTML articles as tag-free, direct-paste text."""

from __future__ import annotations

from html.parser import HTMLParser
from pathlib import Path

HERE = Path(__file__).parent


def to_unicode_bold(value: str) -> str:
    """Render emphasized ASCII text with paste-safe Unicode bold glyphs."""
    transformed: list[str] = []
    for character in value:
        if "A" <= character <= "Z":
            transformed.append(chr(ord(character) - ord("A") + 0x1D400))
        elif "a" <= character <= "z":
            transformed.append(chr(ord(character) - ord("a") + 0x1D41A))
        elif "0" <= character <= "9":
            transformed.append(chr(ord(character) - ord("0") + 0x1D7CE))
        else:
            transformed.append(character)
    return "".join(transformed)


class ArticleParser(HTMLParser):
    """Convert semantic article HTML into clean plain text."""

    BLOCK_TAGS = {"h1", "h2", "p", "blockquote", "figcaption", "pre"}
    SKIP_TAGS = {"head", "script", "style"}

    def __init__(self) -> None:
        super().__init__()
        self.blocks: list[str] = []
        self.current: list[str] = []
        self.skip_depth = 0
        self.strong_depth = 0
        self.in_list_item = False

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        if tag in self.SKIP_TAGS:
            self.skip_depth += 1
            return
        if self.skip_depth:
            return
        if tag == "strong":
            self.strong_depth += 1
        elif tag == "li":
            self.flush()
            self.current.append("• ")
            self.in_list_item = True
        elif tag in self.BLOCK_TAGS:
            self.flush()

    def handle_endtag(self, tag: str) -> None:
        if tag in self.SKIP_TAGS:
            self.skip_depth -= 1
            return
        if self.skip_depth:
            return
        if tag == "strong":
            self.strong_depth -= 1
        elif tag == "li":
            self.flush()
            self.in_list_item = False
        elif tag in self.BLOCK_TAGS:
            self.flush()

    def handle_data(self, data: str) -> None:
        if self.skip_depth:
            return
        normalized = " ".join(data.split())
        if not normalized:
            return
        if self.current and not self.current[-1].endswith((" ", "\n")):
            self.current.append(" ")
        self.current.append(to_unicode_bold(normalized) if self.strong_depth else normalized)

    def flush(self) -> None:
        value = "".join(self.current).strip()
        if value:
            self.blocks.append(value)
        self.current = []

    def output(self) -> str:
        self.flush()
        return "\n\n".join(self.blocks) + "\n"


def main() -> None:
    for html_path in sorted(HERE.glob("[0-9][0-9]-what-the-stream-phase-[0-9][0-9].html")):
        parser = ArticleParser()
        parser.feed(html_path.read_text())
        html_path.with_suffix(".txt").write_text(parser.output())


if __name__ == "__main__":
    main()
