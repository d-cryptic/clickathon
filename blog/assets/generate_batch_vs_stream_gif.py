"""Generate the animated batch-versus-stream processing blog diagram."""

from __future__ import annotations

import math
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

WIDTH = 1_200
HEIGHT = 675
SCALE = 2
FRAME_COUNT = 48
FRAME_DURATION_MS = 80

BACKGROUND = "#F8F6F1"
INK = "#1F2933"
MUTED = "#66737F"
AMBER = "#C97819"
AMBER_DARK = "#9A5B13"
AMBER_LIGHT = "#FFF4D8"
TEAL = "#218F80"
TEAL_DARK = "#176C61"
TEAL_LIGHT = "#DDF5EF"
WHITE = "#FFFFFF"

OUTPUT_PATH = Path(__file__).with_name("batch-vs-stream-processing.gif")
FONT_REGULAR = "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf"
FONT_BOLD = "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf"


def font(size: int, *, bold: bool = False) -> ImageFont.FreeTypeFont:
    """Load a consistently available publication font."""
    return ImageFont.truetype(FONT_BOLD if bold else FONT_REGULAR, size * SCALE)


def box(
    draw: ImageDraw.ImageDraw,
    bounds: tuple[int, int, int, int],
    *,
    fill: str,
    outline: str | None = None,
    radius: int = 16,
    width: int = 2,
) -> None:
    """Draw a scaled rounded rectangle."""
    scaled = tuple(value * SCALE for value in bounds)
    draw.rounded_rectangle(
        scaled,
        radius=radius * SCALE,
        fill=fill,
        outline=outline,
        width=width * SCALE,
    )


def text(
    draw: ImageDraw.ImageDraw,
    position: tuple[int, int],
    value: str,
    *,
    size: int,
    color: str,
    bold: bool = False,
    anchor: str = "mm",
) -> None:
    """Draw scaled text."""
    draw.text(
        (position[0] * SCALE, position[1] * SCALE),
        value,
        font=font(size, bold=bold),
        fill=color,
        anchor=anchor,
    )


def arrow(
    draw: ImageDraw.ImageDraw,
    start: tuple[int, int],
    end: tuple[int, int],
    *,
    color: str,
) -> None:
    """Draw a horizontal connector with an arrow head."""
    start_x, start_y = start
    end_x, end_y = end
    draw.line(
        (start_x * SCALE, start_y * SCALE, (end_x - 10) * SCALE, end_y * SCALE),
        fill=color,
        width=4 * SCALE,
    )
    draw.polygon(
        [
            (end_x * SCALE, end_y * SCALE),
            ((end_x - 13) * SCALE, (end_y - 8) * SCALE),
            ((end_x - 13) * SCALE, (end_y + 8) * SCALE),
        ],
        fill=color,
    )


def moving_dot(
    draw: ImageDraw.ImageDraw,
    start_x: int,
    end_x: int,
    y: int,
    progress: float,
    *,
    color: str,
    radius: int = 7,
) -> None:
    """Draw one animated dot along a horizontal connector."""
    x = start_x + ((end_x - start_x) * progress)
    draw.ellipse(
        (
            (x - radius) * SCALE,
            (y - radius) * SCALE,
            (x + radius) * SCALE,
            (y + radius) * SCALE,
        ),
        fill=color,
        outline=WHITE,
        width=2 * SCALE,
    )


def draw_batch_panel(draw: ImageDraw.ImageDraw, phase: float) -> None:
    """Draw finite-input batch processing and its scheduled movement."""
    box(draw, (50, 115, 565, 615), fill="#FFF9ED", outline="#E5B25D", radius=18)
    text(draw, (84, 155), "BATCH PROCESSING", size=22, color=AMBER_DARK, bold=True, anchor="lm")
    box(draw, (385, 141, 530, 171), fill="#F5D99E", radius=15)
    text(draw, (457, 156), "KNOWN, FINITE INPUT", size=10, color="#7A470D", bold=True)
    box(draw, (85, 225, 225, 370), fill=WHITE, outline="#D99A31", radius=12)
    text(draw, (155, 246), "COLLECT FIRST", size=11, color=AMBER_DARK, bold=True)
    for x_position in (105, 165):
        box(draw, (x_position, 278, x_position + 42, 327), fill=AMBER_LIGHT, outline="#D99A31", radius=4)
        text(draw, (x_position + 21, 303), "FILE", size=9, color="#71400A", bold=True)
    box(draw, (285, 257, 390, 339), fill=AMBER, outline="#A65E0B", radius=14)
    text(draw, (337, 291), "PROCESS", size=14, color=WHITE, bold=True)
    text(draw, (337, 315), "on schedule", size=10, color=WHITE)
    box(draw, (445, 257, 530, 339), fill=AMBER_LIGHT, outline="#D99A31", radius=12)
    text(draw, (487, 291), "SNAPSHOT", size=12, color="#71400A", bold=True)
    text(draw, (487, 315), "result", size=10, color="#71400A")
    arrow(draw, (225, 298), (285, 298), color=AMBER)
    arrow(draw, (390, 298), (445, 298), color=AMBER)
    if phase < 0.45:
        movement = phase / 0.45
        for delay in (0.0, 0.18, 0.36):
            progress = min(1.0, max(0.0, movement - delay))
            moving_dot(draw, 230, 280, 298, progress, color="#F5B942")
    elif phase < 0.75:
        movement = (phase - 0.45) / 0.30
        for delay in (0.0, 0.16, 0.32):
            progress = min(1.0, max(0.0, movement - delay))
            moving_dot(draw, 395, 440, 298, progress, color="#F5B942")
    box(draw, (90, 435, 525, 495), fill=AMBER_LIGHT, radius=10)
    text(
        draw,
        (307, 465),
        "All input is available before processing begins.",
        size=13,
        color="#71400A",
    )
    text(
        draw,
        (307, 545),
        "1  Collect data     2  Run the batch     3  Publish a snapshot",
        size=11,
        color=AMBER_DARK,
    )


def draw_stream_panel(draw: ImageDraw.ImageDraw, phase: float) -> None:
    """Draw continuously arriving events and uninterrupted movement."""
    box(draw, (635, 115, 1150, 615), fill="#EFFAF8", outline="#55AE9F", radius=18)
    text(draw, (669, 155), "STREAM PROCESSING", size=22, color=TEAL_DARK, bold=True, anchor="lm")
    box(draw, (970, 141, 1115, 171), fill="#BEE8DF", radius=15)
    text(draw, (1042, 156), "CONTINUOUS INPUT", size=10, color="#115B52", bold=True)
    text(draw, (670, 225), "EVENTS ARRIVE OVER TIME", size=10, color=TEAL_DARK, bold=True, anchor="lm")
    arrow(draw, (650, 298), (850, 298), color=TEAL)
    box(draw, (850, 257, 960, 339), fill=TEAL, outline=TEAL_DARK, radius=14)
    text(draw, (905, 291), "PROCESS", size=14, color=WHITE, bold=True)
    text(draw, (905, 315), "continuously", size=10, color=WHITE)
    arrow(draw, (960, 298), (1030, 298), color=TEAL)
    box(draw, (1030, 257, 1115, 339), fill=TEAL_LIGHT, outline=TEAL, radius=12)
    text(draw, (1072, 291), "UPDATED", size=12, color="#115B52", bold=True)
    text(draw, (1072, 315), "result", size=10, color="#115B52")
    for offset in (0.0, 0.22, 0.44, 0.66, 0.88):
        progress = (phase + offset) % 1.0
        if progress < 0.68:
            moving_dot(draw, 655, 845, 298, progress / 0.68, color="#62C7B5")
        else:
            moving_dot(draw, 965, 1025, 298, (progress - 0.68) / 0.32, color="#62C7B5")
    text(draw, (1072, 390), "∞", size=30, color=TEAL, bold=True)
    box(draw, (675, 435, 1110, 495), fill=TEAL_LIGHT, radius=10)
    text(
        draw,
        (892, 465),
        "New events are processed as they happen.",
        size=13,
        color="#115B52",
    )
    text(
        draw,
        (892, 545),
        "1  Receive event     2  Process now     3  Update the result",
        size=11,
        color=TEAL_DARK,
    )


def create_frame(frame_number: int) -> Image.Image:
    """Create one antialiased animation frame."""
    image = Image.new("RGB", (WIDTH * SCALE, HEIGHT * SCALE), BACKGROUND)
    draw = ImageDraw.Draw(image)
    phase = frame_number / FRAME_COUNT
    text(
        draw,
        (600, 48),
        "BATCH PROCESSING vs. STREAM PROCESSING",
        size=25,
        color=INK,
        bold=True,
    )
    text(
        draw,
        (600, 82),
        "Finite input on a schedule vs. continuously arriving data",
        size=13,
        color=MUTED,
    )
    draw.line(
        (600 * SCALE, 120 * SCALE, 600 * SCALE, 600 * SCALE),
        fill="#D9D6CF",
        width=2 * SCALE,
    )
    draw_batch_panel(draw, phase)
    draw_stream_panel(draw, phase)
    pulse = 0.55 + (0.35 * math.sin(phase * math.tau))
    footer_color = tuple(
        int(int(MUTED[index : index + 2], 16) * pulse)
        for index in (1, 3, 5)
    )
    text(
        draw,
        (600, 645),
        "The difference is when input becomes available and when processing happens.",
        size=12,
        color=footer_color,
    )
    return image.resize((WIDTH, HEIGHT), Image.Resampling.LANCZOS)


def main() -> None:
    """Render and save the looping GIF."""
    frames = [create_frame(frame_number) for frame_number in range(FRAME_COUNT)]
    frames[0].save(
        OUTPUT_PATH,
        save_all=True,
        append_images=frames[1:],
        duration=FRAME_DURATION_MS,
        loop=0,
        disposal=2,
        optimize=True,
    )


if __name__ == "__main__":
    main()
