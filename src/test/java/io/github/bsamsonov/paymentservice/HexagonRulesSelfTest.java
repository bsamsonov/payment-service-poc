package io.github.bsamsonov.paymentservice;

import static org.assertj.core.api.Assertions.assertThat;

import com.tngtech.archunit.core.domain.JavaClasses;
import com.tngtech.archunit.core.importer.ClassFileImporter;
import com.tngtech.archunit.lang.ArchRule;
import com.tngtech.archunit.lang.EvaluationResult;
import java.util.stream.Stream;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.Arguments;
import org.junit.jupiter.params.provider.MethodSource;

/**
 * Proves that every rule can fail: each one is evaluated against deliberately broken classes in {@code archfixture.bad}
 * (one module) and {@code archfixture.app} (module layout) and must report the expected class. Without this, a rule
 * with a typo in a package pattern, or one whose package does not exist yet, is green forever.
 */
class HexagonRulesSelfTest {

    private static final JavaClasses BAD = new ClassFileImporter().importPackages("archfixture.bad");
    private static final JavaClasses GOOD = new ClassFileImporter().importPackages("archfixture.good");
    private static final JavaClasses BAD_APP = new ClassFileImporter().importPackages("archfixture.app");
    private static final JavaClasses GOOD_APP = new ClassFileImporter().importPackages("archfixture.goodapp");
    private static final HexagonRules BAD_RULES = new HexagonRules("archfixture.bad");
    private static final HexagonRules GOOD_RULES = new HexagonRules("archfixture.good");
    private static final ModuleRules BAD_MODULES = new ModuleRules("archfixture.app", "archfixture.app.AppMain");
    private static final ModuleRules GOOD_MODULES =
            new ModuleRules("archfixture.goodapp", "archfixture.goodapp.GoodApp");

    static Stream<Arguments> rules() {
        return Stream.of(
                Arguments.of("M-01", BAD_MODULES.everyClassBelongsToAModule(), BAD_APP, "StrayClass"),
                Arguments.of("M-01", BAD_MODULES.everyClassBelongsToAModule(), BAD_APP, "RootLayer"),
                Arguments.of("M-02", BAD_MODULES.modulesAreFreeOfCycles(), BAD_APP, "Alpha"),
                Arguments.of("H-01", BAD_RULES.domainIsPlainJava(), BAD, "BadDomain"),
                Arguments.of("H-02", BAD_RULES.applicationKnowsNoAdaptersAndNoTechnology(), BAD, "BadUseCase"),
                Arguments.of("H-03", BAD_RULES.portsSpeakDomainLanguage(), BAD, "BadPort"),
                Arguments.of("H-04", BAD_RULES.webDoesNotUsePorts(), BAD, "BadController"),
                Arguments.of("H-05", BAD_RULES.adaptersDoNotDependOnEachOther(), BAD, "BadController"),
                Arguments.of("H-06", BAD_RULES.adapterClassesAreNotPublic(), BAD, "BadEntity"),
                Arguments.of("H-07", BAD_RULES.generatedApiStaysInWebAdapter(), BAD, "BadUseCase"),
                Arguments.of("H-08", BAD_RULES.endpointsComeFromTheContract(), BAD, "BadController"),
                Arguments.of("H-09", BAD_RULES.jpaStaysInPersistenceAdapter(), BAD, "BadConfig"),
                Arguments.of("H-10", BAD_RULES.webStereotypesStayInWebAdapter(), BAD, "BadConfig"),
                Arguments.of("H-11", BAD_RULES.onlyTheApplicationClassSeesConfig(), BAD, "BadUseCase"),
                Arguments.of("H-12", BAD_RULES.noPackageCycles(), BAD, "BadDomain"),
                Arguments.of("T-01", TestConventionsTest.UNIT_TESTS_NEED_NO_DOCKER, BAD, "BadContextTest"));
    }

    @ParameterizedTest(name = "{0} reports {3}")
    @MethodSource("rules")
    void ruleCatchesItsViolation(String id, ArchRule rule, JavaClasses classes, String expectedClass) {
        EvaluationResult result = rule.evaluate(classes);

        assertThat(result.hasViolation()).as(id).isTrue();
        assertThat(result.getFailureReport().toString()).as(id).contains(expectedClass);
    }

    @Test
    void cleanCodePassesTheAllowListRules() {
        assertThat(GOOD_RULES.domainIsPlainJava().evaluate(GOOD).hasViolation()).isFalse();
        assertThat(GOOD_RULES.portsSpeakDomainLanguage().evaluate(GOOD).hasViolation())
                .isFalse();
    }

    @Test
    void cleanModuleLayoutPassesTheModuleRules() {
        assertThat(GOOD_MODULES.everyClassBelongsToAModule().evaluate(GOOD_APP).hasViolation())
                .isFalse();
        assertThat(GOOD_MODULES.modulesAreFreeOfCycles().evaluate(GOOD_APP).hasViolation())
                .isFalse();
    }
}
