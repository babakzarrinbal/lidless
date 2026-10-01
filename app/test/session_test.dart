import 'package:flutter_test/flutter_test.dart';
import 'package:macremote/model/terms.dart';
import 'package:macremote/ui/new_session.dart';

void main() {
  test('agent command', () {
    expect(Terms.command('claude', ''), 'claude');
    expect(Terms.command('copilot', ' --allow-all-tools '), 'copilot --allow-all-tools');
    expect(Terms.command('cli', ''), isNull);
    expect(Terms.command('cli', 'npm run dev'), 'npm run dev');
  });

  test('restart flags continue instead of resume', () {
    expect(continueFlags(''), '--continue');
    expect(continueFlags('--resume abc --model opus'), '--continue --model opus');
    expect(continueFlags('-c --dangerously-skip-permissions'), '--continue --dangerously-skip-permissions');
    expect(continueFlags('--resume --model sonnet'), '--continue --model sonnet');
  });
}
