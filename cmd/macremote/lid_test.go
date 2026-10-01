package main

import "testing"

func TestLidParse(t *testing.T) {
	out := `+-o AppleSMCKeysEndpoint  <class AppleSMCKeysEndpoint>
    {
      "AppleClamshellCausesSleep" = Yes
      "AppleClamshellState" = Yes
    }
`
	if shut, alone := lidParse(out); !shut || !alone {
		t.Fatalf("shut lid: got %v %v", shut, alone)
	}
	if shut, alone := lidParse(`"AppleClamshellState" = No` + "\n" + `"AppleClamshellCausesSleep" = No`); shut || alone {
		t.Fatalf("open lid: got %v %v", shut, alone)
	}
}
