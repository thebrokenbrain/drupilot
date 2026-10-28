#!/usr/bin/env bash
# The test labels and the declared floor (lab L-1.0-D9: the adapted tests of
# optimizedb passed $this->t('...') to submitForm(), green on 11.4 and 10.6,
# a TypeError on the declared floor 10.2):
# - php_markup_label_lines finds a submitForm() label (second argument) and a
#   buttonExists() / buttonNotExists() locator that is a translated string
#   object, also across lines; a (string) cast, a literal, another argument,
#   another method are fine;
# - check-port-safety.sh test-label-markup reports each in a file under
#   tests/ while the range admits a core below 10.3 (config/port-checks.json
#   since): a warning unattributed, an error (exit 3) when the port added it;
#   nothing for ^10.3 || ^11, nor outside tests/.
# Docker-free.
. "$(dirname "${BASH_SOURCE[0]}")/../lib/assert.sh"
t_isolate
# shellcheck source=../../scripts/lib/common.sh
. "$T_LIB"
# shellcheck source=../../scripts/lib/php-scan.sh
. "$T_REPO/scripts/lib/php-scan.sh"
CPS="$T_REPO/scripts/analysis/check-port-safety.sh"

M="$T_TMP/lm"; mkdir -p "$M/tests/src/Functional" "$M/src"
printf 'name: LM\ntype: module\ncore_version_requirement: ^10.2 || ^11\n' > "$M/lm.info.yml"
cat > "$M/tests/src/Functional/LabelTest.php" <<'EOF'
<?php

namespace Drupal\Tests\lm\Functional;

class LabelTest extends \Drupal\Tests\BrowserTestBase {
  public function testLabels() {
    $this->submitForm([], $this->t('Optimize tables'));
    $this->submitForm([], (string) $this->t('Check tables'));
    $this->submitForm(['a' => $this->t('x')], 'Save');
    $this->submitForm([
      'name' => 'x',
    ], t('Save configuration'));
    $this->assertSession()->buttonExists($this->t('Save'));
    $this->assertSession()->buttonNotExists(new TranslatableMarkup('Delete'));
    $this->assertSession()->buttonExists('Save');
    $this->submitFormX([], $this->t('No'));
  }
}
EOF
printf '<?php\nfunction lm_x($o) { $o->submitForm([], $o->t("Not a test")); }\n' > "$M/src/Helper.php"
php_code_lines "$M/tests/src/Functional/LabelTest.php" > "$T_TMP/blank"
assert_eq "php_markup_label_lines: the translated labels, by line" \
  "$(php_markup_label_lines "$T_TMP/blank" | tr '\t' ':' | tr '\n' ' ')" "7:submitForm 12:submitForm 13:buttonExists 14:buttonNotExists "

t_run "$T_SH" "$CPS" --subject "$M" --no-diff --checks test-label-markup --json
assert_eq "check-port-safety: unattributed, a warning per label (exit 0), tests/ only" \
  "$T_RC|$(jq -c '[.findings[] | [.file, .line, .severity]]' "$T_OUT")" \
  '0|[["tests/src/Functional/LabelTest.php",7,"warn"],["tests/src/Functional/LabelTest.php",12,"warn"],["tests/src/Functional/LabelTest.php",13,"warn"],["tests/src/Functional/LabelTest.php",14,"warn"]]'
assert_match "  the message says why and what to pass" "$(jq -r '.findings[0].message' "$T_OUT")" \
  "admits 10\\.2\\.0: before 10\\.3, core's WebAssert passes it to Mink's findButton\\(string\\).*\\(string\\) \\\$this->t"
t_run "$T_SH" "$CPS" --subject "$M" --no-diff --checks test-label-markup --core-req '^10.3 || ^11' --json
assert_eq "^10.3 || ^11: nothing" "$T_RC|$(jq -c '.findings | length' "$T_OUT")" "0|0"
t_run "$T_SH" "$CPS" --subject "$M" --no-diff --checks test-label-markup --core-req '^11' --json
assert_eq "^11: nothing" "$(jq -c '.findings | length' "$T_OUT")" "0"

# Attributed: a label the port added is an error, the stage is not done.
g() { git -C "$M" -c user.name=t -c user.email=t@example.invalid -c commit.gpgsign=false "$@"; }
cp "$M/tests/src/Functional/LabelTest.php" "$T_TMP/after.php"
sed "s/\$this->submitForm(\[\], \$this->t('Optimize tables'));/\$this->submitForm([], 'Optimize tables');/" "$T_TMP/after.php" > "$M/tests/src/Functional/LabelTest.php"
g init -q; g add -A; g commit -qm base
cp "$T_TMP/after.php" "$M/tests/src/Functional/LabelTest.php"
t_run "$T_SH" "$CPS" --subject "$M" --checks test-label-markup --base HEAD --json
assert_eq "diff mode: the label the port added is an error (exit 3), the others warnings" \
  "$T_RC|$(jq -c '[.findings[] | [.line, .introduced, .severity]]' "$T_OUT")" \
  '3|[[7,true,"error"],[12,false,"warn"],[13,false,"warn"],[14,false,"warn"]]'
t_done
