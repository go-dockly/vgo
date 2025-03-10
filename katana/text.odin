package katana

import "base:intrinsics"
import "core:fmt"
import "core:io"
import "core:math"
import "core:math/linalg"
import "core:mem"
import "core:strings"
import "core:unicode"
import "core:unicode/utf8"

Text_Justify :: enum {
	Left,
	Center,
	Right,
}

Text_Wrap :: enum {
	None,
	Character,
	Word,
}

Text_Glyph :: struct {
	using glyph: Font_Glyph,
	code:        rune,
	index:       int,
	line:        int,
	offset:      [2]f32,
}

Text_Line :: struct {
	offset:      [2]f32,
	size:        [2]f32,
	index_range: [2]int,
	glyph_range: [2]int,
}

Text :: struct {
	font:             Font,
	font_scale:       f32,
	glyphs:           []Text_Glyph,
	lines:            []Text_Line,
	size:             [2]f32,
	selection_lines:  [2]int,
	selection_glyphs: [2]int,
}

Text_Selection :: struct {
	valid: bool,
	index: int,
	line:  int,
	glyph: int,
}

Selectable_Text :: struct {
	using text: Text,
	selection:  Text_Selection,
}

Text_Builder :: struct {
	reader:     io.Reader,
	font:       Font,
	font_size:  f32,
	spacing:    f32,
	max_width:  f32,
	max_height: f32,
	wrap:       Text_Wrap,
	glyph:      Font_Glyph,
	line_width: f32,
	new_line:   bool,
	at_end:     bool,
	offset:     [2]f32,
	last_char:  rune,
	char:       rune,
	next_word:  int,
	index:      int,
	next_index: int,
}

text_is_empty :: proc(text: ^Text) -> bool {
	return len(text.glyphs) == 0
}

make_text :: proc(
	s: string,
	size: f32,
	font: Font = core.current_font,
	wrap: Text_Wrap = .None,
	justify: f32 = 0,
	max_size: [2]f32 = math.F32_MAX,
	selection: Maybe([2]int) = nil,
	allocator: mem.Allocator = context.temp_allocator,
) -> (
	text: Text,
) {
	reader: strings.Reader
	return make_text_with_reader(
		strings.to_reader(&reader, s),
		size,
		font,
		wrap,
		justify,
		max_size,
		selection,
		allocator,
	)
}

make_text_with_reader :: proc(
	reader: io.Reader,
	size: f32,
	font: Font = core.current_font,
	wrap: Text_Wrap = .None,
	justify: f32 = 0,
	max_size: [2]f32 = math.F32_MAX,
	selection: Maybe([2]int) = nil,
	allocator: mem.Allocator = context.temp_allocator,
) -> (
	text: Text,
) {
	iter: Text_Builder = {
		font       = font,
		font_size  = size,
		reader     = reader,
		max_width  = max_size.x,
		max_height = max_size.y,
		wrap       = wrap,
	}

	glyphs := make([dynamic]Text_Glyph, allocator = allocator)
	lines := make([dynamic]Text_Line, allocator = allocator)

	line: Text_Line = {
		glyph_range = {},
	}
	line_height := (font.ascend - font.descend) * size

	text.font_scale = size
	text.font = font

	for iterate_text(&iter) {
		if iter.new_line || iter.at_end {
			current_line := len(lines)

			line.glyph_range[1] = len(glyphs)
			line.size = {iter.line_width, font.line_height * size}
			line_offset: [2]f32
			line_offset.x -= line.size.x * justify

			for &glyph in glyphs[line.glyph_range[0]:line.glyph_range[1]] {
				glyph.offset += line_offset
			}
			line.offset += line_offset

			line.glyph_range[1] -= int(iter.new_line && !iter.at_end)

			new_line := Text_Line {
				glyph_range = {0 = len(glyphs)},
				offset = iter.offset,
			}

			text.size.x = max(text.size.x, line.size.x)
			text.size.y += font.line_height * size
			append(&lines, line)

			line = new_line
		}

		glyph_index := len(glyphs)
		line_index := len(lines)
		if selection, ok := selection.?; ok {
			if selection.x > selection.y {
				selection = selection.yx
			}
			if selection[0] == iter.index {
				text.selection_glyphs[0] = glyph_index
				text.selection_lines[0] = line_index
			}
			if selection[1] == iter.index {
				text.selection_glyphs[1] = glyph_index
				text.selection_lines[1] = line_index
			}
		}

		if iter.at_end {
			iter.glyph = {}
			iter.char = 0
		}

		// Add a glyph last so that `len(core.text_glyphs)` is the index of this glyph
		append(
			&glyphs,
			Text_Glyph {
				line = line_index,
				glyph = iter.glyph,
				code = iter.char,
				index = iter.index,
				offset = iter.offset,
			},
		)
	}

	text.glyphs = glyphs[:]
	text.lines = lines[:]

	return
}

make_selectable :: proc(text: Text, point: [2]f32) -> Selectable_Text {
	text := Selectable_Text {
		text = text,
	}

	closest: f32 = math.F32_MAX

	text.selection.glyph = -1
	text.selection.line = clamp(
		int(point.y / (text.font.line_height * text.font_scale)),
		0,
		len(text.lines) - 1,
	)

	for &line, line_index in text.lines {
		line_box := Box{line.offset, line.offset + line.size}
		if point.x >= line_box.lo.x &&
		   point.x < line_box.hi.x &&
		   point.y >= line_box.lo.y &&
		   point.y < line_box.hi.y {
			text.selection.valid = true
		}
	}

	line := &text.lines[text.selection.line]
	for &glyph, glyph_index in text.glyphs[line.glyph_range.x:min(line.glyph_range.y + 1, len(text.glyphs))] {
		distance := abs(glyph.offset.x - point.x)
		if distance < closest {
			closest = distance
			text.selection.index = glyph.index
			text.selection.glyph = glyph_index
		}
		if glyph_index == len(text.glyphs) - 1 {
			text.selection.line = min(text.selection.line, glyph.line)
		}
	}

	return text
}

find_font_glyph :: proc(font: Font, char: rune) -> Font_Glyph {
	glyph: Font_Glyph
	ok: bool
	glyph, ok = get_font_glyph(font, char)
	if !ok && char > unicode.MAX_LATIN1 && core.fallback_font != nil {
		glyph, ok = get_font_glyph(core.fallback_font.?, char)
	}
	return glyph
}

@(private)
closest_line_of_text :: proc(offset, text_height, line_height: f32) -> Maybe(int) {
	line_count := int(math.floor(text_height / line_height))
	mouse_line := int(offset / line_height)
	return mouse_line if (mouse_line >= 0 && mouse_line < line_count) else nil
}

@(private)
first_word_in :: proc(
	reader: io.Reader,
	font: Font,
	size: f32,
	spacing: f32,
) -> (
	end: int,
	width: f32,
) {
	for i := 0; true; {
		char, bytes, err := io.read_rune(reader)
		if err == .EOF {
			end = i + bytes
			break
		}
		if char != '\n' {
			if glyph, ok := get_font_glyph(font, char); ok {
				width += glyph.advance * size + spacing
			}
		}
		i += bytes
	}
	return
}

iterate_text :: proc(iter: ^Text_Builder) -> bool {
	if iter.at_end {
		return false
	}

	if iter.new_line {
		iter.line_width = iter.glyph.advance * iter.font_size + iter.spacing
	}

	if iter.char != 0 {
		iter.offset.x += iter.glyph.advance * iter.font_size + iter.spacing
	}

	iter.last_char = iter.char
	char_len: int
	err: io.Error
	iter.char, char_len, err = io.read_rune(iter.reader)
	if err == .EOF {
		iter.at_end = true
	} else {
		iter.glyph = find_font_glyph(iter.font, iter.char)
	}

	space := iter.glyph.advance * iter.font_size

	if iter.at_end {
		iter.index = iter.next_index
		iter.char = 0
		iter.glyph = {}
	} else if (iter.wrap == .Word) && (iter.index >= iter.next_word) && (iter.char != ' ') {
		iter.next_word, space = first_word_in(iter.reader, iter.font, iter.font_size, iter.spacing)
	}

	iter.new_line = false

	if iter.last_char == '\n' {
		iter.new_line = true
	} else {
		if iter.line_width + space > iter.max_width {
			if iter.wrap == .None {
				iter.at_end = true
			} else {
				iter.new_line = true
			}
		}
	}

	if iter.new_line {
		iter.offset.x = 0
		iter.offset.y += iter.font.line_height * iter.font_size
		if iter.offset.y + iter.font.line_height * iter.font_size >= iter.max_height {
			iter.at_end = true
			return false
		}
	} else {
		iter.line_width += iter.glyph.advance * iter.font_size
		if !iter.at_end {
			iter.line_width += iter.spacing
		}
	}

	return true
}

add_text :: proc(text: Text, origin: [2]f32, paint: Paint_Option = nil) {
	for &glyph in text.glyphs {
		add_glyph(
			glyph,
			text.font_scale,
			origin + glyph.offset,
			paint = paint_index_from_option(paint),
			bias = glyph_bias_from_paint(paint),
		)
	}
}

add_text_range :: proc(text: Text, range: [2]int, origin: [2]f32, paint: Paint_Option = nil) {
	for &glyph in text.glyphs[range[0]:max(range[0], range[1])] {
		add_glyph(
			glyph,
			text.font_scale,
			origin + glyph.offset,
			paint = paint_index_from_option(paint),
			bias = glyph_bias_from_paint(paint),
		)
	}
}

// A sort of gamma correction for text drawn in SRGB color space
glyph_bias_from_paint :: proc(paint: Paint_Option) -> f32 {
	if core.renderer.surface_config.format != .RGBA8UnormSrgb &&
	   core.renderer.surface_config.format != .BGRA8UnormSrgb {
		return 0.0
	}
	if color, ok := paint.(Color); ok {
		return 0.5 - luminance_of(color) * 0.5
	}
	return 0.0
}

add_string :: proc(
	str: string,
	size: f32,
	origin: [2]f32,
	align: [2]f32 = 0,
	justify: f32 = 0,
	paint: Paint_Option = nil,
) -> [2]f32 {
	text := make_text(str, size, font = core.current_font, justify = justify)
	add_text(text, origin - text.size * align, paint)
	return text.size
}

add_string_wrapped :: proc(
	str: string,
	size: f32,
	box: Box,
	align: [2]f32 = 0,
	paint: Paint_Option = nil,
) -> [2]f32 {
	text := make_text(
		str,
		size,
		font = core.current_font,
		max_size = box.hi - box.lo,
		wrap = .Character,
		justify = align.x,
	)
	add_text(text, math.lerp(box.lo, box.hi, align), paint)
	return text.size
}

make_glyph :: proc(glyph: Font_Glyph, size: f32, origin: [2]f32, bias: f32 = 0) -> Shape {
	return Shape {
		kind = .Glyph,
		tex_min = glyph.source.lo / core.atlas_size,
		tex_max = glyph.source.hi / core.atlas_size,
		quad_min = origin + glyph.bounds.lo * size,
		quad_max = origin + glyph.bounds.hi * size,
		radius = {0 = bias},
	}
}

add_rune :: proc(
	char: rune,
	size: f32,
	origin: [2]f32,
	align: [2]f32 = 0,
	font: Font = core.current_font,
	paint: Paint_Option = nil,
) -> u32 {
	glyph, ok := get_font_glyph(font, char)
	if !ok {
		fmt.printfln("Unable to find font glyph '%c'", char)
		return 0
	}
	return add_glyph(
		glyph,
		size,
		origin - {glyph.advance, font.line_height} * align * size,
		paint = paint,
	)
}

add_glyph :: proc(
	glyph: Font_Glyph,
	size: f32,
	origin: [2]f32,
	paint: Paint_Option = nil,
	bias: f32 = 0.0,
) -> u32 {
	shape := make_glyph(glyph, size, origin, bias)
	shape.paint = paint_index_from_option(paint)
	return add_shape(shape)
}

add_text_scaffold :: proc(text: Text, origin: [2]f32) {
	for &line in text.lines {
		add_box_lines({origin + line.offset, origin + line.offset + line.size}, 1, paint = Red)
	}
}
