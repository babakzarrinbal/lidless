// What the key bar and the Mac shortcuts type: the control byte for a key and
// the line-editing sequences for ⌘ and ⌥ with the arrows.
import 'package:xterm/xterm.dart';

int ctrlCode(int c) {
  if (c >= 0x61 && c <= 0x7a) return c - 0x60; // a-z
  if (c >= 0x40 && c <= 0x5f) return c - 0x40; // @ A-Z [ \ ] ^ _
  if (c == 0x20) return 0;
  if (c == 0x3f) return 0x7f;
  return c;
}

  const cmdKeys = {
    'k': '\x0c', // clear the screen
    '.': '\x03', // interrupt
    'a': '\x01', // start of line
    'e': '\x05',
    'z': '\x1f', // readline undo
  };


  // Mac line editing: ⌘ jumps to the line's ends, ⌥ moves by word.
  const cmdArrows = {
    TerminalKey.arrowLeft: '\x01',
    TerminalKey.arrowRight: '\x05',
    TerminalKey.backspace: '\x15',
    TerminalKey.delete: '\x0b',
  };
  const optArrows = {
    TerminalKey.arrowLeft: '\x1bb',
    TerminalKey.arrowRight: '\x1bf',
    TerminalKey.backspace: '\x1b\x7f',
    TerminalKey.delete: '\x1bd',
  };
