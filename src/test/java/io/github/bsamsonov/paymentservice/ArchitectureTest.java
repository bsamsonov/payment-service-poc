package io.github.bsamsonov.paymentservice;

import static com.tngtech.archunit.lang.syntax.ArchRuleDefinition.noClasses;
import static com.tngtech.archunit.library.GeneralCodingRules.NO_CLASSES_SHOULD_ACCESS_STANDARD_STREAMS;
import static com.tngtech.archunit.library.GeneralCodingRules.NO_CLASSES_SHOULD_THROW_GENERIC_EXCEPTIONS;
import static com.tngtech.archunit.library.GeneralCodingRules.NO_CLASSES_SHOULD_USE_FIELD_INJECTION;
import static com.tngtech.archunit.library.GeneralCodingRules.NO_CLASSES_SHOULD_USE_JAVA_UTIL_LOGGING;
import static com.tngtech.archunit.library.dependencies.SlicesRuleDefinition.slices;

import com.tngtech.archunit.core.importer.ImportOption;
import com.tngtech.archunit.junit.AnalyzeClasses;
import com.tngtech.archunit.junit.ArchTest;
import com.tngtech.archunit.lang.ArchRule;

/**
 * Architecture rules enforced on production code. Layering rules are added together with the layers they protect (see
 * specs).
 */
@AnalyzeClasses(packagesOf = ArchitectureTest.class, importOptions = ImportOption.DoNotIncludeTests.class)
class ArchitectureTest {

    @ArchTest
    static final ArchRule noFieldInjection = NO_CLASSES_SHOULD_USE_FIELD_INJECTION.allowEmptyShould(true);

    @ArchTest
    static final ArchRule noStandardStreams = NO_CLASSES_SHOULD_ACCESS_STANDARD_STREAMS;

    @ArchTest
    static final ArchRule noGenericExceptions = NO_CLASSES_SHOULD_THROW_GENERIC_EXCEPTIONS;

    @ArchTest
    static final ArchRule noJavaUtilLogging = NO_CLASSES_SHOULD_USE_JAVA_UTIL_LOGGING;

    // Layering (spec 001 plan). allowEmptyShould: rules stay green until the packages exist.

    @ArchTest
    static final ArchRule domainIsFrameworkFree = noClasses()
            .that()
            .resideInAPackage("..paymentservice.domain..")
            .should()
            .dependOnClassesThat()
            .resideInAnyPackage(
                    "org.springframework..",
                    "jakarta.persistence..",
                    "org.hibernate..",
                    "tools.jackson..",
                    "com.fasterxml.jackson..")
            .allowEmptyShould(true);

    @ArchTest
    static final ArchRule applicationDoesNotDependOnAdapters = noClasses()
            .that()
            .resideInAPackage("..paymentservice.application..")
            .should()
            .dependOnClassesThat()
            .resideInAPackage("..paymentservice.adapter..")
            .allowEmptyShould(true);

    @ArchTest
    static final ArchRule inboundAndOutboundAdaptersAreIndependent = noClasses()
            .that()
            .resideInAPackage("..paymentservice.adapter.in..")
            .should()
            .dependOnClassesThat()
            .resideInAPackage("..paymentservice.adapter.out..")
            .allowEmptyShould(true);

    @ArchTest
    static final ArchRule outboundAdaptersDoNotDependOnInbound = noClasses()
            .that()
            .resideInAPackage("..paymentservice.adapter.out..")
            .should()
            .dependOnClassesThat()
            .resideInAPackage("..paymentservice.adapter.in..")
            .allowEmptyShould(true);

    @ArchTest
    static final ArchRule outboundAdaptersDoNotDependOnEachOther = slices().matching(
                    "..paymentservice.adapter.out.(*)..")
            .should()
            .notDependOnEachOther()
            .allowEmptyShould(true);

    @ArchTest
    static final ArchRule generatedApiIsUsedOnlyByWebAdapter = noClasses()
            .that()
            .resideOutsideOfPackage("..paymentservice.adapter.in.web..")
            .should()
            .dependOnClassesThat()
            .resideInAnyPackage("..paymentservice.adapter.in.web.api..", "..paymentservice.adapter.in.web.model..")
            .allowEmptyShould(true);

    @ArchTest
    static final ArchRule jpaOnlyInPersistenceAdapter = noClasses()
            .that()
            .resideOutsideOfPackage("..paymentservice.adapter.out.persistence..")
            .should()
            .dependOnClassesThat()
            .resideInAnyPackage("jakarta.persistence..", "org.hibernate..")
            .allowEmptyShould(true);
}
