package io.github.bsamsonov.paymentservice;

import static com.tngtech.archunit.library.GeneralCodingRules.NO_CLASSES_SHOULD_ACCESS_STANDARD_STREAMS;
import static com.tngtech.archunit.library.GeneralCodingRules.NO_CLASSES_SHOULD_THROW_GENERIC_EXCEPTIONS;
import static com.tngtech.archunit.library.GeneralCodingRules.NO_CLASSES_SHOULD_USE_FIELD_INJECTION;
import static com.tngtech.archunit.library.GeneralCodingRules.NO_CLASSES_SHOULD_USE_JAVA_UTIL_LOGGING;

import com.tngtech.archunit.core.importer.ImportOption;
import com.tngtech.archunit.junit.AnalyzeClasses;
import com.tngtech.archunit.junit.ArchTest;
import com.tngtech.archunit.lang.ArchRule;

/**
 * Architecture rules enforced on production code. The rules and their fix hints are in {@link ModuleRules} and
 * {@link HexagonRules}; {@link HexagonRulesSelfTest} proves that each of them can fail.
 */
@AnalyzeClasses(packagesOf = ArchitectureTest.class, importOptions = ImportOption.DoNotIncludeTests.class)
class ArchitectureTest {

    private static final String ROOT = "io.github.bsamsonov.paymentservice";
    private static final ModuleRules MODULES = new ModuleRules(ROOT, PaymentServiceApplication.class.getName());
    private static final HexagonRules PAYMENT = new HexagonRules(ROOT + ".payment");

    @ArchTest
    static final ArchRule noFieldInjection = NO_CLASSES_SHOULD_USE_FIELD_INJECTION.allowEmptyShould(true);

    @ArchTest
    static final ArchRule noStandardStreams = NO_CLASSES_SHOULD_ACCESS_STANDARD_STREAMS;

    @ArchTest
    static final ArchRule noGenericExceptions = NO_CLASSES_SHOULD_THROW_GENERIC_EXCEPTIONS;

    @ArchTest
    static final ArchRule noJavaUtilLogging = NO_CLASSES_SHOULD_USE_JAVA_UTIL_LOGGING;

    // allowEmptyShould(true) marks a rule whose package does not exist yet. Remove it in the PR that adds the package.

    @ArchTest
    static final ArchRule m01 = MODULES.everyClassBelongsToAModule().allowEmptyShould(true);

    @ArchTest
    static final ArchRule m02 = MODULES.modulesAreFreeOfCycles().allowEmptyShould(true);

    // Module payment.

    @ArchTest
    static final ArchRule paymentH01 = PAYMENT.domainIsPlainJava().allowEmptyShould(true);

    @ArchTest
    static final ArchRule paymentH02 =
            PAYMENT.applicationKnowsNoAdaptersAndNoTechnology().allowEmptyShould(true);

    @ArchTest
    static final ArchRule paymentH03 = PAYMENT.portsSpeakDomainLanguage().allowEmptyShould(true);

    @ArchTest
    static final ArchRule paymentH04 = PAYMENT.webDoesNotUsePorts().allowEmptyShould(true);

    @ArchTest
    static final ArchRule paymentH05 = PAYMENT.adaptersDoNotDependOnEachOther().allowEmptyShould(true);

    @ArchTest
    static final ArchRule paymentH06 = PAYMENT.adapterClassesAreNotPublic().allowEmptyShould(true);

    @ArchTest
    static final ArchRule paymentH07 = PAYMENT.generatedApiStaysInWebAdapter().allowEmptyShould(true);

    @ArchTest
    static final ArchRule paymentH08 = PAYMENT.endpointsComeFromTheContract().allowEmptyShould(true);

    @ArchTest
    static final ArchRule paymentH09 = PAYMENT.jpaStaysInPersistenceAdapter().allowEmptyShould(true);

    @ArchTest
    static final ArchRule paymentH10 = PAYMENT.webStereotypesStayInWebAdapter().allowEmptyShould(true);

    @ArchTest
    static final ArchRule paymentH11 =
            PAYMENT.onlyTheApplicationClassSeesConfig().allowEmptyShould(true);

    @ArchTest
    static final ArchRule paymentH12 = PAYMENT.noPackageCycles().allowEmptyShould(true);
}
