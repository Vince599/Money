#!/usr/bin/env bash
# Pure scope selection shared by the macOS build and local contract checks.
configure_validation_scope() {
  VALIDATION_SCOPE="${LEDGER_VALIDATION_SCOPE:-business}"
  UI_SUITE="${LEDGER_UI_SUITE:-all}"
  PACKAGE_IPA="${LEDGER_PACKAGE_IPA:-false}"
  # Retain the explicit scope used by run #42 as a compatibility alias.
  if [[ "$VALIDATION_SCOPE" == "calculator" ]]; then
    VALIDATION_SCOPE=ui
    UI_SUITE=calculator
  fi
  case "$VALIDATION_SCOPE" in
    compile|business|ui|full) ;;
    *) printf 'Unsupported validation scope: %s\n' "$VALIDATION_SCOPE" >&2; return 1 ;;
  esac
  case "$PACKAGE_IPA" in
    true|false) ;;
    *) printf '%s\n' 'LEDGER_PACKAGE_IPA must be true or false.' >&2; return 1 ;;
  esac
  if [[ "$PACKAGE_IPA" == true && "$VALIDATION_SCOPE" != full ]]; then
    printf '%s\n' 'IPA packaging requires full validation in this run.' >&2
    return 1
  fi
  case "$UI_SUITE" in
    all) UI_TEST_TARGET=LedgerUITests ;;
    calculator) UI_TEST_TARGET=LedgerUITests/LedgerUITests/testCalculatorCopyAndSearchFilters ;;
    imports) UI_TEST_TARGET=LedgerUITests/LedgerUITests/testImportPartialCommitFilterPersistenceAndUndo ;;
    refunds) UI_TEST_TARGET=LedgerUITests/LedgerUITests/testRefundShowsOriginalAndNetCostThenRequiresExplicitGroupDeletion ;;
    categories) UI_TEST_TARGET=LedgerUITests/LedgerUITests/testCategoryIconSearchCancelSaveRelaunchAndRestoreDefault ;;
    tags) UI_TEST_TARGET=LedgerUITests/LedgerUITests/testTagsAndProjectPersistAndFilterAfterProjectArchive ;;
    accounts) UI_TEST_TARGET=LedgerUITests/LedgerUITests/testAccountTemplateDefaultsAndSavedAppearanceSurviveRelaunch ;;
    entries) UI_TEST_TARGET=LedgerUITests/LedgerUITests/testCreateExpensePersistsAfterRelaunch ;;
    *) printf 'Unsupported UI suite: %s\n' "$UI_SUITE" >&2; return 1 ;;
  esac
  RUN_PACKAGE_TESTS=false
  RUN_UI_TESTS=false
  SIMULATOR_ACTION=test
  SIMULATOR_TEST_ARGS=(-parallel-testing-enabled NO)
  case "$VALIDATION_SCOPE" in
    compile) SIMULATOR_ACTION=build-for-testing ;;
    business)
      RUN_PACKAGE_TESTS=true
      SIMULATOR_TEST_ARGS+=('-only-testing:LedgerAppTests') ;;
    ui)
      RUN_UI_TESTS=true
      SIMULATOR_TEST_ARGS+=("-only-testing:$UI_TEST_TARGET") ;;
    full)
      RUN_PACKAGE_TESTS=true
      RUN_UI_TESTS=true ;;
  esac
}
