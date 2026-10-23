/* Type 1 fonts as OpenType, for the pages Live Preview writes as PDF.
 *
 * MuPDF's PDF writer embeds a Type 1 font program as the descendant of a CID font, which PDF
 * doesn't allow (CID fonts take CID-keyed CFF or TrueType programs): PDF viewers other than
 * MuPDF draw the wrong glyphs, or the text in a substitute font. The glyphs a Type 1 font shows
 * go to the page through an OpenType copy of it instead: a CID-keyed CFF with the same glyphs
 * in the same order, CID i being glyph i, and a Unicode cmap from the glyphs' names, from which
 * MuPDF writes the ToUnicode map that copying and finding text need. The Type 1 font still
 * answers the DVI's glyph lookups. */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <ft2build.h>
#include FT_FREETYPE_H
#include FT_OUTLINE_H
#include FT_FONT_FORMATS_H
#include <mupdf/fitz.h>
#include "mydvi.h"

typedef struct { unsigned char *data; size_t len, cap; int failed; } cff_buf;

static void put(cff_buf *b, const void *p, size_t n)
{
  if (b->failed) return;
  if (b->len + n > b->cap)
  {
    size_t cap = b->cap ? b->cap * 2 : 4096;
    while (cap < b->len + n) cap *= 2;
    unsigned char *data = realloc(b->data, cap);
    if (!data) { b->failed = 1; return; }
    b->data = data;
    b->cap = cap;
  }
  memcpy(b->data + b->len, p, n);
  b->len += n;
}

static void put8(cff_buf *b, int v) { unsigned char c = v; put(b, &c, 1); }
static void put16(cff_buf *b, int v) { put8(b, v >> 8); put8(b, v); }
static void put32(cff_buf *b, long v) { put16(b, (int)(v >> 16)); put16(b, (int)(v & 0xffff)); }

/* A Type 2 charstring operand, or a DICT one: the same encodings up to two bytes. */
static void put_number(cff_buf *b, long v, int dict)
{
  if (v >= -107 && v <= 107)
    put8(b, (int)v + 139);
  else if (v >= 108 && v <= 1131)
  {
    v -= 108;
    put8(b, (int)(v >> 8) + 247);
    put8(b, (int)v);
  }
  else if (v >= -1131 && v <= -108)
  {
    v = -v - 108;
    put8(b, (int)(v >> 8) + 251);
    put8(b, (int)v);
  }
  else if (dict && (v < -32768 || v > 32767))
  {
    put8(b, 29);
    put32(b, v);
  }
  else
  {
    if (v < -32768) v = -32768;
    if (v > 32767) v = 32767;
    put8(b, 28);
    put16(b, (int)v);
  }
}

/* A DICT offset at a fixed five bytes, so the DICT's size is known before its offsets. */
static void put_offset(cff_buf *b, long v) { put8(b, 29); put32(b, v); }

/* An INDEX of `count` items, `data` holding them end to end and `ends` where each ends. */
static void put_index(cff_buf *b, const unsigned char *data, const size_t *ends, int count)
{
  put16(b, count);
  if (count == 0) return;
  size_t total = ends[count - 1];
  int size = total + 1 < 0x100 ? 1 : total + 1 < 0x10000 ? 2 : total + 1 < 0x1000000 ? 3 : 4;
  put8(b, size);
  for (int i = 0; i <= count; i++)
  {
    size_t offset = (i ? ends[i - 1] : 0) + 1;
    for (int k = size - 1; k >= 0; k--)
      put8(b, (int)(offset >> (8 * k)));
  }
  put(b, data, total);
}

static size_t index_size(size_t total, int count)
{
  if (count == 0) return 2;
  int size = total + 1 < 0x100 ? 1 : total + 1 < 0x10000 ? 2 : total + 1 < 0x1000000 ? 3 : 4;
  return 3 + (size_t)size * (count + 1) + total;
}

/* The outline, in 1000 units to the em, as Type 2 operators; the advance leads the first. */
typedef struct { cff_buf *b; double scale; long x, y; long width; int started; } outline_state;

static long units(outline_state *s, FT_Pos v) { return lround(v * s->scale); }

static void start(outline_state *s)
{
  if (!s->started) put_number(s->b, s->width, 0);
  s->started = 1;
}

static int move_to(const FT_Vector *to, void *user)
{
  outline_state *s = user;
  long x = units(s, to->x), y = units(s, to->y);
  start(s);
  put_number(s->b, x - s->x, 0);
  put_number(s->b, y - s->y, 0);
  put8(s->b, 21); /* rmoveto */
  s->x = x; s->y = y;
  return 0;
}

static int line_to(const FT_Vector *to, void *user)
{
  outline_state *s = user;
  long x = units(s, to->x), y = units(s, to->y);
  put_number(s->b, x - s->x, 0);
  put_number(s->b, y - s->y, 0);
  put8(s->b, 5); /* rlineto */
  s->x = x; s->y = y;
  return 0;
}

static void curve(outline_state *s, long x1, long y1, long x2, long y2, long x3, long y3)
{
  put_number(s->b, x1 - s->x, 0);
  put_number(s->b, y1 - s->y, 0);
  put_number(s->b, x2 - x1, 0);
  put_number(s->b, y2 - y1, 0);
  put_number(s->b, x3 - x2, 0);
  put_number(s->b, y3 - y2, 0);
  put8(s->b, 8); /* rrcurveto */
  s->x = x3; s->y = y3;
}

static int cubic_to(const FT_Vector *c1, const FT_Vector *c2, const FT_Vector *to, void *user)
{
  outline_state *s = user;
  curve(s, units(s, c1->x), units(s, c1->y), units(s, c2->x), units(s, c2->y), units(s, to->x), units(s, to->y));
  return 0;
}

/* Type 1 has no quadratic curves; a font FreeType gives one for still converts. */
static int conic_to(const FT_Vector *c, const FT_Vector *to, void *user)
{
  outline_state *s = user;
  long cx = units(s, c->x), cy = units(s, c->y), x = units(s, to->x), y = units(s, to->y);
  curve(s, lround(s->x + 2.0 * (cx - s->x) / 3), lround(s->y + 2.0 * (cy - s->y) / 3),
        lround(x + 2.0 * (cx - x) / 3), lround(y + 2.0 * (cy - y) / 3), x, y);
  return 0;
}

typedef struct { const char *tag; cff_buf data; } sfnt_table;

static unsigned long checksum(const cff_buf *t)
{
  unsigned long sum = 0;
  for (size_t i = 0; i < t->len; i++)
    sum += (unsigned long)t->data[i] << (24 - 8 * (i & 3));
  return sum & 0xffffffff;
}

/* An OpenType font around a CID-keyed CFF (malloc'd, `*len` bytes), or NULL on a failure. */
static unsigned char *opentype(FT_Face face, const cff_buf *cff, const long *advance,
                               const long bbox[4], size_t *len)
{
  int n = face->num_glyphs;
  long widest = 0;
  for (int gid = 0; gid < n; gid++)
    if (advance[gid] > widest) widest = advance[gid];
  enum { CFF, CMAP, HEAD, HHEA, HMTX, MAXP, NAME, POST, TABLES };
  sfnt_table t[TABLES] = { {"CFF "}, {"cmap"}, {"head"}, {"hhea"}, {"hmtx"}, {"maxp"},
                           {"name"}, {"post"} };
  put(&t[CFF].data, cff->data, cff->len);

  /* Unicode from the glyphs' names, which FreeType reads into a charmap of a Type 1 face. */
  FT_CharMap encoding = face->charmap;
  cff_buf groups = {0};
  long ngroups = 0;
  if (!FT_Select_Charmap(face, FT_ENCODING_UNICODE))
  {
    FT_UInt gid;
    for (FT_ULong ucs = FT_Get_First_Char(face, &gid); gid; ucs = FT_Get_Next_Char(face, ucs, &gid))
    {
      put32(&groups, (long)ucs); put32(&groups, (long)ucs); put32(&groups, gid);
      ngroups++;
    }
    FT_Set_Charmap(face, encoding);
  }
  put16(&t[CMAP].data, 0); put16(&t[CMAP].data, 1);
  put16(&t[CMAP].data, 3); put16(&t[CMAP].data, 10); put32(&t[CMAP].data, 12);
  put16(&t[CMAP].data, 12); put16(&t[CMAP].data, 0); put32(&t[CMAP].data, 16 + 12 * ngroups);
  put32(&t[CMAP].data, 0); put32(&t[CMAP].data, ngroups);
  put(&t[CMAP].data, groups.data, groups.len);
  t[CMAP].data.failed |= groups.failed;
  free(groups.data);

  cff_buf *h = &t[HEAD].data;
  put32(h, 0x10000); put32(h, 0x10000); put32(h, 0); put32(h, 0x5F0F3CF5);
  put16(h, 3); put16(h, 1000);
  for (int k = 0; k < 4; k++) put32(h, 0); /* created, modified */
  for (int k = 0; k < 4; k++) put16(h, (int)bbox[k]);
  put16(h, 0); put16(h, 8); put16(h, 2); put16(h, 0); put16(h, 0);

  h = &t[HHEA].data;
  put32(h, 0x10000); put16(h, (int)bbox[3]); put16(h, (int)bbox[1]); put16(h, 0);
  put16(h, (int)widest); put16(h, 0); put16(h, 0); put16(h, (int)bbox[2]);
  put16(h, 1); put16(h, 0); put16(h, 0);
  for (int k = 0; k < 5; k++) put16(h, 0);
  put16(h, n);

  for (int gid = 0; gid < n; gid++) { put16(&t[HMTX].data, (int)advance[gid]); put16(&t[HMTX].data, 0); }
  put32(&t[MAXP].data, 0x5000); put16(&t[MAXP].data, n);

  /* Its family, full and PostScript names, which some viewers want of an embedded font. */
  const char *ps_name = FT_Get_Postscript_Name(face);
  if (!ps_name || !*ps_name) ps_name = "Type1";
  int name_len = (int)strlen(ps_name);
  h = &t[NAME].data;
  put16(h, 0); put16(h, 3); put16(h, 6 + 3 * 12);
  for (int k = 0; k < 3; k++)
  {
    put16(h, 3); put16(h, 1); put16(h, 0x409); put16(h, (int[]){ 1, 4, 6 }[k]);
    put16(h, 2 * name_len); put16(h, 0);
  }
  for (int k = 0; k < name_len; k++) put16(h, (unsigned char)ps_name[k]);

  put32(&t[POST].data, 0x30000); /* no glyph names */
  for (int k = 0; k < 7; k++) put32(&t[POST].data, 0);

  cff_buf out = {0};
  int search = 1, selector = 0;
  while (search * 2 <= TABLES) { search *= 2; selector++; }
  put32(&out, 0x4F54544F); put16(&out, TABLES); put16(&out, 16 * search);
  put16(&out, selector); put16(&out, 16 * (TABLES - search));
  size_t at = 12 + 16 * TABLES;
  for (int k = 0; k < TABLES; k++)
  {
    put(&out, t[k].tag, 4); put32(&out, (long)checksum(&t[k].data));
    put32(&out, (long)at); put32(&out, (long)t[k].data.len);
    at += (t[k].data.len + 3) & ~(size_t)3;
  }
  int failed = 0;
  for (int k = 0; k < TABLES; k++)
  {
    put(&out, t[k].data.data, t[k].data.len);
    while (out.len & 3) put8(&out, 0);
    failed |= t[k].data.failed;
    free(t[k].data.data);
  }
  if (failed || out.failed)
  {
    free(out.data);
    return NULL;
  }
  /* head's checkSumAdjustment makes the whole font sum to the magic number. */
  unsigned long adjust = (0xB1B0AFBAUL - checksum(&out)) & 0xffffffff;
  size_t head_at = 12 + 16 * TABLES;
  for (int k = 0; k < HEAD; k++) head_at += (t[k].data.len + 3) & ~(size_t)3;
  for (int k = 0; k < 4; k++) out.data[head_at + 8 + k] = (unsigned char)(adjust >> (24 - 8 * k));
  *len = out.len;
  return out.data;
}

/* A Type 1 face as OpenType (malloc'd, `*len` bytes), or NULL for another kind of font, or a
 * failure. CID i is glyph i, the face's glyph i with its advance; hints go. */
static unsigned char *type1_to_opentype(FT_Face face, size_t *len)
{
  const char *format = FT_Get_Font_Format(face);
  if (!format || strcmp(format, "Type 1") || face->num_glyphs < 1 || face->num_glyphs > 0xffff)
    return NULL;

  int n = face->num_glyphs;
  double scale = face->units_per_EM ? 1000.0 / face->units_per_EM : 1;
  size_t *glyph_ends = calloc(n, sizeof *glyph_ends);
  long *advance = calloc(n, sizeof *advance);
  cff_buf glyphs = {0}, fixed = {0}, top = {0}, fd = {0}, out = {0};
  if (!glyph_ends || !advance)
  {
    free(glyph_ends); free(advance);
    return NULL;
  }

  /* Charstrings, from FreeType's outlines in font units. */
  FT_Outline_Funcs funcs = { move_to, line_to, conic_to, cubic_to, 0, 0 };
  for (int gid = 0; gid < n; gid++)
  {
    outline_state s = { &glyphs, scale, 0, 0, 0, 0 };
    if (!FT_Load_Glyph(face, gid, FT_LOAD_NO_SCALE | FT_LOAD_NO_HINTING | FT_LOAD_NO_BITMAP))
    {
      s.width = lround(face->glyph->metrics.horiAdvance * scale);
      if (face->glyph->format == FT_GLYPH_FORMAT_OUTLINE)
        FT_Outline_Decompose(&face->glyph->outline, &funcs, &s);
    }
    start(&s);
    put8(&glyphs, 14); /* endchar */
    glyph_ends[gid] = glyphs.len;
    advance[gid] = s.width;
  }

  const char *ps_name = FT_Get_Postscript_Name(face);
  if (!ps_name || !*ps_name) ps_name = "Type1";
  size_t name_len = strlen(ps_name);
  static const char strings[] = "AdobeIdentity"; /* SIDs 391 and 392, for the ROS */
  static const size_t string_ends[] = { 5, 13 };

  /* The Top DICT: everything after it is laid out from its size. */
  long bbox[4] = { lround(face->bbox.xMin * scale), lround(face->bbox.yMin * scale),
                   lround(face->bbox.xMax * scale), lround(face->bbox.yMax * scale) };
  put_number(&fixed, 391, 1); put_number(&fixed, 392, 1); put_number(&fixed, 0, 1);
  put8(&fixed, 12); put8(&fixed, 30); /* ROS: Adobe-Identity-0 */
  for (int k = 0; k < 4; k++) put_number(&fixed, bbox[k], 1);
  put8(&fixed, 5); /* FontBBox */
  put_number(&fixed, n, 1); put8(&fixed, 12); put8(&fixed, 34); /* CIDCount */
  size_t top_len = fixed.len + 6 + 6 + 7 + 7, fd_len = 11;
  unsigned char private_dict[] = { 139, 20, 139, 21 }; /* defaultWidthX 0, nominalWidthX 0 */

  size_t charset_at = 4 + index_size(name_len, 1) + index_size(top_len, 1)
                      + index_size(sizeof strings - 1, 2) + index_size(0, 0);
  size_t fdselect_at = charset_at + 1 + 2 * (size_t)(n - 1);
  size_t charstrings_at = fdselect_at + 8;
  size_t fdarray_at = charstrings_at + index_size(glyphs.len, n);
  size_t private_at = fdarray_at + index_size(fd_len, 1);

  put(&top, fixed.data, fixed.len);
  put_offset(&top, (long)charset_at); put8(&top, 15);
  put_offset(&top, (long)charstrings_at); put8(&top, 17);
  put_offset(&top, (long)fdarray_at); put8(&top, 12); put8(&top, 36);
  put_offset(&top, (long)fdselect_at); put8(&top, 12); put8(&top, 37);
  size_t top_end = top.len;
  put_offset(&fd, (long)sizeof private_dict); put_offset(&fd, (long)private_at); put8(&fd, 18);
  size_t fd_end = fd.len;

  put8(&out, 1); put8(&out, 0); put8(&out, 4); put8(&out, 4); /* Header */
  put_index(&out, (const unsigned char *)ps_name, &name_len, 1);
  put_index(&out, top.data, &top_end, 1);
  put_index(&out, (const unsigned char *)strings, string_ends, 2);
  put_index(&out, NULL, NULL, 0); /* Global Subrs */
  put8(&out, 0); /* charset, format 0: glyph i is CID i */
  for (int gid = 1; gid < n; gid++) put16(&out, gid);
  put8(&out, 3); put16(&out, 1); put16(&out, 0); put8(&out, 0); put16(&out, n); /* FDSelect */
  put_index(&out, glyphs.data, glyph_ends, n);
  put_index(&out, fd.data, &fd_end, 1);
  put(&out, private_dict, sizeof private_dict);

  int failed = glyphs.failed || fixed.failed || top.failed || fd.failed || out.failed
               || top.len != top_len || fd.len != fd_len
               || out.len != private_at + sizeof private_dict;
  unsigned char *font = failed ? NULL : opentype(face, &out, advance, bbox, len);
  free(glyph_ends); free(advance);
  free(glyphs.data); free(fixed.data); free(top.data); free(fd.data); free(out.data);
  return font;
}

/* Each Type 1 font met and its OpenType copy (NULL when it couldn't be made), for the session. */
typedef struct page_font { fz_font *font, *copy; struct page_font *next; } page_font;
static page_font *page_fonts, *last;
static bool page_fonts_on;

void dvi_page_fonts(fz_context *ctx, bool on)
{
  while (page_fonts)
  {
    page_font *next = page_fonts->next;
    fz_drop_font(ctx, page_fonts->font);
    fz_drop_font(ctx, page_fonts->copy);
    fz_free(ctx, page_fonts);
    page_fonts = next;
  }
  last = NULL;
  page_fonts_on = on;
}

fz_font *dvi_page_font(fz_context *ctx, fz_font *font)
{
  if (!page_fonts_on || !font)
    return font;
  if (!last || last->font != font)
  {
    for (last = page_fonts; last && last->font != font; last = last->next);
    if (!last)
    {
      last = fz_malloc_struct(ctx, page_font);
      /* Kept, so another font can't come to have its address. */
      last->font = fz_keep_font(ctx, font);
      last->next = page_fonts;
      page_fonts = last;
      size_t len;
      unsigned char *data = NULL;
      FT_Face face = fz_font_ft_face(ctx, font);
      /* MuPDF's FreeType allocates through the context only while it's locked. */
      if (face)
      {
        fz_ft_lock(ctx);
        data = type1_to_opentype(face, &len);
        fz_ft_unlock(ctx);
      }
      if (data)
      {
        fz_buffer *buf = NULL;
        fz_var(buf);
        fz_try(ctx)
        {
          buf = fz_new_buffer_from_copied_data(ctx, data, len);
          last->copy = fz_new_font_from_buffer(ctx, fz_font_name(ctx, font), buf, 0, 0);
        }
        fz_always(ctx)
          fz_drop_buffer(ctx, buf);
        fz_catch(ctx)
          fz_warn(ctx, "%s stays Type 1 in the PDF: %s", fz_font_name(ctx, font), fz_caught_message(ctx));
        free(data);
      }
    }
  }
  return last->copy ? last->copy : font;
}
