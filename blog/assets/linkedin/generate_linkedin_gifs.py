"""Generate animated diagrams for LinkedIn stream-processing articles."""

from __future__ import annotations

from pathlib import Path
from typing import Callable

from PIL import Image, ImageDraw, ImageFont

WIDTH = 960
HEIGHT = 540
SCALE = 2
FRAMES = 30
DURATION_MS = 100

BG = "#F8F6F1"
INK = "#1F2933"
MUTED = "#66737F"
AMBER = "#C97819"
AMBER_LIGHT = "#FFF4D8"
TEAL = "#218F80"
TEAL_LIGHT = "#DDF5EF"
BLUE = "#5F7F9F"
BLUE_LIGHT = "#DDE6EF"
RED = "#D96C5F"
RED_LIGHT = "#FFF2F0"
WHITE = "#FFFFFF"

HERE = Path(__file__).parent
FONT_REGULAR = "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf"
FONT_BOLD = "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf"


def get_font(size: int, bold: bool = False) -> ImageFont.FreeTypeFont:
    return ImageFont.truetype(FONT_BOLD if bold else FONT_REGULAR, size * SCALE)


def text(
    draw: ImageDraw.ImageDraw,
    xy: tuple[int, int],
    value: str,
    size: int,
    color: str = INK,
    bold: bool = False,
    anchor: str = "mm",
) -> None:
    draw.text(
        (xy[0] * SCALE, xy[1] * SCALE),
        value,
        font=get_font(size, bold),
        fill=color,
        anchor=anchor,
    )


def box(
    draw: ImageDraw.ImageDraw,
    bounds: tuple[int, int, int, int],
    fill: str,
    outline: str | None = None,
    radius: int = 14,
    width: int = 2,
) -> None:
    draw.rounded_rectangle(
        tuple(value * SCALE for value in bounds),
        radius=radius * SCALE,
        fill=fill,
        outline=outline,
        width=width * SCALE,
    )


def node(
    draw: ImageDraw.ImageDraw,
    bounds: tuple[int, int, int, int],
    title: str,
    subtitle: str,
    fill: str,
    outline: str,
    text_color: str,
) -> None:
    box(draw, bounds, fill, outline)
    center_x = (bounds[0] + bounds[2]) // 2
    center_y = (bounds[1] + bounds[3]) // 2
    text(draw, (center_x, center_y - 10), title, 13, text_color, True)
    text(draw, (center_x, center_y + 14), subtitle, 9, text_color)


def arrow(
    draw: ImageDraw.ImageDraw,
    start: tuple[int, int],
    end: tuple[int, int],
    color: str,
    width: int = 4,
) -> None:
    draw.line(
        (start[0] * SCALE, start[1] * SCALE, (end[0] - 11) * SCALE, end[1] * SCALE),
        fill=color,
        width=width * SCALE,
    )
    draw.polygon(
        [
            (end[0] * SCALE, end[1] * SCALE),
            ((end[0] - 13) * SCALE, (end[1] - 8) * SCALE),
            ((end[0] - 13) * SCALE, (end[1] + 8) * SCALE),
        ],
        fill=color,
    )


def dot(
    draw: ImageDraw.ImageDraw,
    start: tuple[int, int],
    end: tuple[int, int],
    progress: float,
    color: str,
    radius: int = 7,
) -> None:
    x = start[0] + ((end[0] - start[0]) * progress)
    y = start[1] + ((end[1] - start[1]) * progress)
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


def flow_dots(
    draw: ImageDraw.ImageDraw,
    start: tuple[int, int],
    end: tuple[int, int],
    phase: float,
    color: str,
    count: int = 4,
) -> None:
    for index in range(count):
        dot(draw, start, end, (phase + (index / count)) % 1.0, color)


def canvas(title_value: str, subtitle: str) -> tuple[Image.Image, ImageDraw.ImageDraw]:
    image = Image.new("RGB", (WIDTH * SCALE, HEIGHT * SCALE), BG)
    draw = ImageDraw.Draw(image)
    text(draw, (WIDTH // 2, 38), title_value, 23, INK, True)
    text(draw, (WIDTH // 2, 70), subtitle, 12, MUTED)
    return image, draw


def finish(image: Image.Image) -> Image.Image:
    return image.resize((WIDTH, HEIGHT), Image.Resampling.LANCZOS)


def phase05_event_state(phase: float) -> Image.Image:
    image, draw = canvas(
        "COMMANDS, EVENTS, AND STATE",
        "Intent is validated; accepted facts are recorded and projected.",
    )
    node(draw, (45, 185, 205, 275), "COMMAND", "Create account", AMBER_LIGHT, AMBER, "#71400A")
    node(draw, (285, 185, 445, 275), "VALIDATE", "check invariants", AMBER_LIGHT, AMBER, "#71400A")
    node(draw, (525, 145, 685, 235), "EVENT LOG", "AccountCreated", TEAL_LIGHT, TEAL, "#115B52")
    node(draw, (755, 145, 915, 235), "PROJECTION", "current state", BLUE_LIGHT, BLUE, "#28445F")
    node(draw, (525, 310, 685, 400), "REJECTION", "command declined", RED_LIGHT, RED, "#7A3730")
    arrow(draw, (205, 230), (285, 230), AMBER)
    arrow(draw, (445, 215), (525, 190), TEAL)
    arrow(draw, (685, 190), (755, 190), TEAL)
    arrow(draw, (445, 245), (525, 355), RED)
    flow_dots(draw, (210, 230), (280, 230), phase, "#F5B942", 2)
    if phase < 0.75:
        flow_dots(draw, (450, 215), (520, 190), phase / 0.75, "#62C7B5", 2)
        flow_dots(draw, (690, 190), (750, 190), phase / 0.75, "#62C7B5", 2)
    else:
        flow_dots(draw, (450, 245), (520, 355), (phase - 0.75) * 4, "#E89186", 1)
    box(draw, (120, 445, 840, 495), WHITE, "#D9D6CF", 10)
    text(
        draw,
        (480, 470),
        "Commands express intent. Events record accepted facts. State is derived.",
        12,
        MUTED,
        True,
    )
    return finish(image)


def phase06_event_log_views(phase: float) -> Image.Image:
    image, draw = canvas(
        "ONE EVENT LOG, MANY READ VIEWS",
        "CQRS separates the write model from purpose-built query projections.",
    )
    node(draw, (55, 190, 225, 290), "COMMAND MODEL", "validate + append", AMBER_LIGHT, AMBER, "#71400A")
    node(draw, (320, 175, 500, 305), "IMMUTABLE LOG", "ordered domain facts", TEAL_LIGHT, TEAL, "#115B52")
    node(draw, (650, 115, 875, 190), "ACCOUNT VIEW", "balance + history", BLUE_LIGHT, BLUE, "#28445F")
    node(draw, (650, 230, 875, 305), "SEARCH VIEW", "denormalized lookup", BLUE_LIGHT, BLUE, "#28445F")
    node(draw, (650, 345, 875, 420), "ANALYTICS VIEW", "behavior + trends", BLUE_LIGHT, BLUE, "#28445F")
    arrow(draw, (225, 240), (320, 240), AMBER)
    for start_y, end_y in ((205, 152), (240, 267), (275, 382)):
        arrow(draw, (500, start_y), (650, end_y), TEAL, 3)
        flow_dots(draw, (505, start_y), (645, end_y), phase, "#62C7B5", 3)
    box(draw, (135, 455, 825, 500), WHITE, "#D9D6CF", 10)
    text(draw, (480, 477), "Read views may lag temporarily; each can rebuild by replaying the log.", 11, MUTED, True)
    return finish(image)


def phase07_stream_pipeline(phase: float) -> Image.Image:
    image, draw = canvas(
        "WHAT A STREAM PROCESSOR CAN DO",
        "Continuous transformations turn input events into useful outputs.",
    )
    node(draw, (35, 140, 185, 220), "EVENTS", "payments", AMBER_LIGHT, AMBER, "#71400A")
    node(draw, (35, 280, 185, 360), "EVENTS", "device signals", AMBER_LIGHT, AMBER, "#71400A")
    node(draw, (275, 190, 455, 310), "OPERATORS", "filter · join · aggregate", TEAL_LIGHT, TEAL, "#115B52")
    node(draw, (565, 105, 735, 185), "DERIVED STREAM", "enriched events", BLUE_LIGHT, BLUE, "#28445F")
    node(draw, (760, 105, 925, 185), "DATABASE", "materialized view", BLUE_LIGHT, BLUE, "#28445F")
    node(draw, (565, 245, 735, 325), "ALERT", "fraud pattern", RED_LIGHT, RED, "#7A3730")
    node(draw, (760, 245, 925, 325), "NOTIFICATION", "human action", RED_LIGHT, RED, "#7A3730")
    node(draw, (565, 385, 735, 465), "METRIC", "rolling average", TEAL_LIGHT, TEAL, "#115B52")
    node(draw, (760, 385, 925, 465), "DASHBOARD", "live trend", TEAL_LIGHT, TEAL, "#115B52")
    for start_y, end_y in ((180, 225), (320, 275)):
        arrow(draw, (185, start_y), (275, end_y), AMBER, 3)
        flow_dots(draw, (190, start_y), (270, end_y), phase, "#F5B942", 3)
    for start_y, end_y in ((220, 145), (250, 285), (280, 425)):
        arrow(draw, (455, start_y), (565, end_y), TEAL, 3)
        flow_dots(draw, (460, start_y), (560, end_y), phase, "#62C7B5", 3)
    for y_value in (145, 285, 425):
        arrow(draw, (735, y_value), (760, y_value), BLUE, 3)
        flow_dots(draw, (740, y_value), (755, y_value), phase, "#8FA7C0", 1)
    return finish(image)


def phase08_event_processing_time(phase: float) -> Image.Image:
    image, draw = canvas(
        "EVENT TIME vs. PROCESSING TIME",
        "A restart can distort processing-time metrics without changing when events occurred.",
    )
    text(draw, (130, 140), "EVENT TIME", 13, TEAL, True)
    text(draw, (130, 325), "PROCESSING TIME", 13, BLUE, True)
    draw.line((190 * SCALE, 145 * SCALE, 900 * SCALE, 145 * SCALE), fill=TEAL, width=4 * SCALE)
    draw.line((190 * SCALE, 330 * SCALE, 900 * SCALE, 330 * SCALE), fill=BLUE, width=4 * SCALE)
    for index in range(12):
        x_value = 220 + (index * 55)
        draw.ellipse(
            ((x_value - 6) * SCALE, 139 * SCALE, (x_value + 6) * SCALE, 151 * SCALE),
            fill=TEAL,
        )
    box(draw, (475, 285, 630, 375), RED_LIGHT, RED)
    text(draw, (552, 310), "PROCESSOR", 12, RED, True)
    text(draw, (552, 337), "restart", 11, RED)
    text(draw, (552, 360), "temporary gap", 9, RED)
    visible = int(phase * 12)
    for index in range(12):
        x_value = 220 + (index * 55)
        if 5 <= index <= 7 and visible < 10:
            continue
        draw.ellipse(
            ((x_value - 6) * SCALE, 324 * SCALE, (x_value + 6) * SCALE, 336 * SCALE),
            fill=BLUE,
        )
    box(draw, (205, 425, 875, 485), WHITE, "#D9D6CF", 10)
    text(draw, (540, 447), "Events stayed steady", 12, TEAL, True)
    text(draw, (540, 471), "The visible dip came from processing delay, not real traffic.", 11, MUTED)
    return finish(image)


def phase08_watermark_late(phase: float) -> Image.Image:
    image, draw = canvas(
        "WATERMARKS AND LATE EVENTS",
        "A watermark estimates progress; earlier events may still arrive.",
    )
    draw.line((80 * SCALE, 235 * SCALE, 880 * SCALE, 235 * SCALE), fill=TEAL, width=4 * SCALE)
    for x_value, label in ((150, "10:01"), (300, "10:02"), (450, "10:03"), (600, "10:04"), (750, "10:05")):
        draw.line((x_value * SCALE, 220 * SCALE, x_value * SCALE, 250 * SCALE), fill=TEAL, width=2 * SCALE)
        text(draw, (x_value, 270), label, 9, MUTED)
    draw.line((600 * SCALE, 135 * SCALE, 600 * SCALE, 345 * SCALE), fill=AMBER, width=4 * SCALE)
    text(draw, (600, 115), "WATERMARK 10:04", 12, AMBER, True)
    late_x = 870 - (phase * 500)
    draw.ellipse(
        ((late_x - 10) * SCALE, 175 * SCALE, (late_x + 10) * SCALE, 195 * SCALE),
        fill=RED,
        outline=WHITE,
        width=2 * SCALE,
    )
    text(draw, (late_x, 155), "event time 10:02", 9, RED, True)
    node(draw, (160, 380, 390, 455), "POLICY 1", "drop + monitor", RED_LIGHT, RED, "#7A3730")
    node(draw, (570, 380, 800, 455), "POLICY 2", "update + emit correction", TEAL_LIGHT, TEAL, "#115B52")
    text(draw, (480, 500), "Late-event behavior is a product decision, not an accident.", 11, MUTED, True)
    return finish(image)


def phase08_window_types(phase: float) -> Image.Image:
    image, draw = canvas(
        "FOUR COMMON WINDOW TYPES",
        "The same event stream can be grouped with different time semantics.",
    )
    lanes = [
        ("TUMBLING", 135, AMBER, "fixed, non-overlapping"),
        ("HOPPING", 235, TEAL, "fixed size + fixed hop"),
        ("SLIDING", 335, BLUE, "moves with evaluation time"),
        ("SESSION", 435, RED, "closes after an inactivity gap"),
    ]
    for title_value, y_value, color, description in lanes:
        text(draw, (90, y_value), title_value, 11, color, True, "lm")
        text(draw, (90, y_value + 22), description, 8, MUTED, False, "lm")
        draw.line((270 * SCALE, y_value * SCALE, 895 * SCALE, y_value * SCALE), fill="#D9D6CF", width=2 * SCALE)
    for start_x in (280, 430, 580, 730):
        box(draw, (start_x, 112, start_x + 145, 158), AMBER_LIGHT, AMBER, 5, 2)
    for start_x in (280, 390, 500, 610, 720):
        box(draw, (start_x, 212, start_x + 220, 258), TEAL_LIGHT, TEAL, 5, 2)
    moving_start = 280 + int(phase * 250)
    box(draw, (moving_start, 312, moving_start + 260, 358), BLUE_LIGHT, BLUE, 5, 2)
    for x_value in (300, 345, 390, 560, 600, 790):
        draw.ellipse(
            ((x_value - 7) * SCALE, 428 * SCALE, (x_value + 7) * SCALE, 442 * SCALE),
            fill=RED,
        )
    box(draw, (285, 410, 415, 460), RED_LIGHT, RED, 8, 2)
    box(draw, (545, 410, 620, 460), RED_LIGHT, RED, 8, 2)
    box(draw, (775, 410, 810, 460), RED_LIGHT, RED, 8, 2)
    return finish(image)


def phase09_stream_stream_join(phase: float) -> Image.Image:
    image, draw = canvas(
        "STREAM–STREAM WINDOW JOIN",
        "Out-of-order search and click events meet in bounded state.",
    )
    node(draw, (45, 140, 215, 220), "SEARCH STREAM", "impression id: q17", AMBER_LIGHT, AMBER, "#71400A")
    node(draw, (45, 330, 215, 410), "CLICK STREAM", "impression id: q17", BLUE_LIGHT, BLUE, "#28445F")
    node(draw, (350, 195, 545, 355), "WINDOW STATE", "index both streams\nby impression id", TEAL_LIGHT, TEAL, "#115B52")
    node(draw, (700, 225, 900, 325), "JOINED RESULT", "search + click", WHITE, TEAL, "#115B52")
    arrow(draw, (215, 180), (350, 235), AMBER, 3)
    arrow(draw, (215, 370), (350, 315), BLUE, 3)
    arrow(draw, (545, 275), (700, 275), TEAL, 4)
    flow_dots(draw, (220, 180), (345, 235), (phase + 0.45) % 1.0, "#F5B942", 2)
    flow_dots(draw, (220, 370), (345, 315), phase, "#8FA7C0", 2)
    flow_dots(draw, (550, 275), (695, 275), phase, "#62C7B5", 3)
    text(draw, (480, 440), "A unique impression id avoids accidental many-to-many matches.", 11, MUTED, True)
    return finish(image)


def phase09_stream_table_join(phase: float) -> Image.Image:
    image, draw = canvas(
        "STREAM–TABLE ENRICHMENT",
        "A local profile view stays current through CDC and enriches activity events.",
    )
    node(draw, (35, 150, 205, 235), "ACTIVITY STREAM", "user id: 42", AMBER_LIGHT, AMBER, "#71400A")
    node(draw, (35, 335, 205, 420), "PROFILE CDC", "user 42 updated", BLUE_LIGHT, BLUE, "#28445F")
    node(draw, (310, 300, 500, 440), "LOCAL PROFILE STORE", "fast lookup\nkept in sync", BLUE_LIGHT, BLUE, "#28445F")
    node(draw, (310, 130, 500, 250), "ENRICH OPERATOR", "lookup user 42", TEAL_LIGHT, TEAL, "#115B52")
    node(draw, (675, 175, 900, 275), "ENRICHED EVENT", "activity + profile", WHITE, TEAL, "#115B52")
    arrow(draw, (205, 192), (310, 190), AMBER, 3)
    arrow(draw, (405, 300), (405, 250), BLUE, 3)
    arrow(draw, (205, 377), (310, 370), BLUE, 3)
    arrow(draw, (500, 190), (675, 225), TEAL, 4)
    flow_dots(draw, (210, 192), (305, 190), phase, "#F5B942", 3)
    flow_dots(draw, (210, 377), (305, 370), phase, "#8FA7C0", 3)
    flow_dots(draw, (505, 190), (670, 225), phase, "#62C7B5", 3)
    return finish(image)


def phase09_table_table_join(phase: float) -> Image.Image:
    image, draw = canvas(
        "CONTINUOUS TABLE–TABLE JOIN",
        "Tweet and follow changelogs maintain precomputed home timelines.",
    )
    node(draw, (35, 140, 215, 225), "TWEET CHANGELOG", "B publishes a tweet", AMBER_LIGHT, AMBER, "#71400A")
    node(draw, (35, 325, 215, 410), "FOLLOW CHANGELOG", "A follows B", BLUE_LIGHT, BLUE, "#28445F")
    node(draw, (330, 190, 530, 360), "MATERIALIZER", "join current tweets\nwith follow graph", TEAL_LIGHT, TEAL, "#115B52")
    node(draw, (675, 135, 900, 220), "A'S HOME TIMELINE", "contains B's tweets", WHITE, TEAL, "#115B52")
    node(draw, (675, 325, 900, 410), "B'S HOME TIMELINE", "contains B's followees", WHITE, BLUE, "#28445F")
    arrow(draw, (215, 182), (330, 230), AMBER, 3)
    arrow(draw, (215, 367), (330, 320), BLUE, 3)
    arrow(draw, (530, 240), (675, 177), TEAL, 4)
    arrow(draw, (530, 310), (675, 367), BLUE, 3)
    flow_dots(draw, (220, 182), (325, 230), phase, "#F5B942", 3)
    flow_dots(draw, (220, 367), (325, 320), phase, "#8FA7C0", 3)
    flow_dots(draw, (535, 240), (670, 177), phase, "#62C7B5", 3)
    text(draw, (480, 465), "Follow direction matters: A follows B, so B's tweets enter A's timeline.", 11, MUTED, True)
    return finish(image)


def phase10_checkpoint_recovery(phase: float) -> Image.Image:
    image, draw = canvas(
        "CHECKPOINT, CRASH, RESTORE, REPLAY",
        "A consistent checkpoint binds source positions to operator state.",
    )
    node(draw, (35, 200, 185, 285), "SOURCE", "replayable log", AMBER_LIGHT, AMBER, "#71400A")
    node(draw, (285, 175, 465, 310), "STATEFUL OPERATOR", "count = 128", TEAL_LIGHT, TEAL, "#115B52")
    node(draw, (555, 115, 725, 200), "CHECKPOINT", "offset 500 + state", BLUE_LIGHT, BLUE, "#28445F")
    node(draw, (555, 300, 725, 385), "CRASH", "volatile state lost", RED_LIGHT, RED, "#7A3730")
    node(draw, (790, 200, 925, 285), "RESTORE", "resume at 501", WHITE, TEAL, "#115B52")
    arrow(draw, (185, 242), (285, 242), AMBER, 3)
    arrow(draw, (465, 205), (555, 157), BLUE, 3)
    arrow(draw, (465, 280), (555, 342), RED, 3)
    arrow(draw, (725, 157), (790, 230), TEAL, 3)
    flow_dots(draw, (190, 242), (280, 242), phase, "#F5B942", 3)
    if phase < 0.6:
        flow_dots(draw, (470, 205), (550, 157), phase / 0.6, "#8FA7C0", 2)
    else:
        flow_dots(draw, (730, 157), (785, 230), (phase - 0.6) / 0.4, "#62C7B5", 2)
    box(draw, (120, 430, 840, 480), WHITE, "#D9D6CF", 10)
    text(draw, (480, 455), "Transactional sinks abort uncommitted output; other sinks may see retries.", 11, MUTED, True)
    return finish(image)


def phase10_idempotence(phase: float) -> Image.Image:
    image, draw = canvas(
        "RETRIES: IDEMPOTENT vs. NON-IDEMPOTENT",
        "Repeating the same operation should not create an additional effect.",
    )
    box(draw, (45, 125, 450, 450), TEAL_LIGHT, TEAL)
    box(draw, (510, 125, 915, 450), RED_LIGHT, RED)
    text(draw, (247, 155), "IDEMPOTENT SET", 16, TEAL, True)
    text(draw, (712, 155), "NON-IDEMPOTENT INCREMENT", 16, RED, True)
    node(draw, (90, 205, 230, 275), "RETRY 1", "set X = 5", WHITE, TEAL, "#115B52")
    node(draw, (90, 315, 230, 385), "RETRY 2", "set X = 5", WHITE, TEAL, "#115B52")
    node(draw, (285, 260, 405, 330), "RESULT", "X = 5", WHITE, TEAL, "#115B52")
    node(draw, (555, 205, 695, 275), "RETRY 1", "counter + 1", WHITE, RED, "#7A3730")
    node(draw, (555, 315, 695, 385), "RETRY 2", "counter + 1", WHITE, RED, "#7A3730")
    node(draw, (750, 260, 870, 330), "RESULT", "+ 2", WHITE, RED, "#7A3730")
    arrow(draw, (230, 240), (285, 282), TEAL, 3)
    arrow(draw, (230, 350), (285, 308), TEAL, 3)
    arrow(draw, (695, 240), (750, 282), RED, 3)
    arrow(draw, (695, 350), (750, 308), RED, 3)
    flow_dots(draw, (235, 240), (280, 282), phase, "#62C7B5", 2)
    flow_dots(draw, (235, 350), (280, 308), (phase + 0.5) % 1.0, "#62C7B5", 2)
    flow_dots(draw, (700, 240), (745, 282), phase, "#E89186", 2)
    flow_dots(draw, (700, 350), (745, 308), (phase + 0.5) % 1.0, "#E89186", 2)
    text(draw, (480, 495), "Partition + offset or an event ID can deduplicate sink retries.", 11, MUTED, True)
    return finish(image)


def phase10_state_recovery(phase: float) -> Image.Image:
    image, draw = canvas(
        "THREE PATHS TO RECOVER STREAMING STATE",
        "Recovery must restore state consistent with source offsets.",
    )
    node(draw, (35, 115, 245, 205), "DURABLE SNAPSHOT", "operator state + offsets", BLUE_LIGHT, BLUE, "#28445F")
    node(draw, (35, 250, 245, 340), "CHANGELOG TOPIC", "compacted state updates", TEAL_LIGHT, TEAL, "#115B52")
    node(draw, (35, 385, 245, 475), "INPUT REPLAY", "bounded source history", AMBER_LIGHT, AMBER, "#71400A")
    node(draw, (385, 210, 575, 380), "RESTORE PROCESS", "load baseline\nthen replay later input", WHITE, TEAL, "#115B52")
    node(draw, (720, 245, 915, 345), "RECOVERED STATE", "ready to continue", TEAL_LIGHT, TEAL, "#115B52")
    for start_y, color in ((160, BLUE), (295, TEAL), (430, AMBER)):
        arrow(draw, (245, start_y), (385, 295), color, 3)
        flow_dots(draw, (250, start_y), (380, 295), phase, color, 3)
    arrow(draw, (575, 295), (720, 295), TEAL, 4)
    flow_dots(draw, (580, 295), (715, 295), phase, "#62C7B5", 3)
    text(draw, (480, 495), "Periodic copying alone is not enough unless offsets and state are coordinated.", 11, MUTED, True)
    return finish(image)


RENDERERS: dict[str, Callable[[float], Image.Image]] = {
    "phase05-event-state.gif": phase05_event_state,
    "phase06-event-log-projections.gif": phase06_event_log_views,
    "phase07-stream-processing-pipeline.gif": phase07_stream_pipeline,
    "phase08-event-vs-processing-time.gif": phase08_event_processing_time,
    "phase08-watermark-late-events.gif": phase08_watermark_late,
    "phase08-window-types.gif": phase08_window_types,
    "phase09-stream-stream-join.gif": phase09_stream_stream_join,
    "phase09-stream-table-enrichment.gif": phase09_stream_table_join,
    "phase09-table-table-materialized-view.gif": phase09_table_table_join,
    "phase10-checkpoint-recovery.gif": phase10_checkpoint_recovery,
    "phase10-idempotence-retries.gif": phase10_idempotence,
    "phase10-state-recovery-options.gif": phase10_state_recovery,
}


def save_animation(filename: str, renderer: Callable[[float], Image.Image]) -> None:
    frames = [renderer(index / FRAMES) for index in range(FRAMES)]
    frames[0].save(
        HERE / filename,
        save_all=True,
        append_images=frames[1:],
        duration=DURATION_MS,
        loop=0,
        disposal=2,
        optimize=True,
    )


def main() -> None:
    for filename, renderer in RENDERERS.items():
        save_animation(filename, renderer)


if __name__ == "__main__":
    main()
