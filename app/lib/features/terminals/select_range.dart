// Where a terminal selection begins and ends, in cells: the span a point
// covers (a caret between two cells, a word, a line) and the selection from a
// fixed anchor span to the moving one. No widgets; term_select.dart drives it.
import 'package:xterm/xterm.dart';

/// What a drag selects by: a mouse drag cells, a double click words, a
/// triple click lines; a long press words, a handle cells.
enum SelUnit { char, word, line }

/// Cells from [begin] (included) to [end] (not included).
typedef Span = ({CellOffset begin, CellOffset end});

/// The span [unit] covers at [cell]. For [SelUnit.char] it is a caret: before
/// the cell, or after it when the point is on its [right] half.
Span spanAt(Buffer b, CellOffset cell, SelUnit unit, {bool right = false}) {
  switch (unit) {
    case SelUnit.char:
      final c = CellOffset(right ? cell.x + 1 : cell.x, cell.y);
      return (begin: c, end: c);
    case SelUnit.word:
      final w = b.getWordBoundary(cell); // null on a space: that cell alone
      return w == null ? (begin: cell, end: CellOffset(cell.x + 1, cell.y)) : (begin: w.begin, end: w.end);
    case SelUnit.line: // the whole line, with the rows it wrapped onto
      var top = cell.y, bottom = cell.y;
      while (top > 0 && b.lines[top].isWrapped) {
        top--;
      }
      while (bottom + 1 < b.lines.length && b.lines[bottom + 1].isWrapped) {
        bottom++;
      }
      return (begin: CellOffset(0, top), end: CellOffset(b.viewWidth, bottom));
  }
}

/// Everything from [a] to [c], whichever comes first.
Span joinSpans(Span a, Span c) => (
      begin: a.begin.isBefore(c.begin) ? a.begin : c.begin,
      end: a.end.isAfter(c.end) ? a.end : c.end,
    );

/// The end of [sel] that stays when a shift+click at [at] moves the other:
/// the one farther away.
CellOffset farEnd(BufferRange sel, CellOffset at, int width) {
  int i(CellOffset o) => o.y * (width + 1) + o.x;
  final s = sel.normalized;
  return (i(at) - i(s.begin)).abs() > (i(s.end) - i(at)).abs() ? s.begin : s.end;
}
