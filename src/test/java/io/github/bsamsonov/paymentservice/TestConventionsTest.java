package io.github.bsamsonov.paymentservice;

import static com.tngtech.archunit.lang.syntax.ArchRuleDefinition.noClasses;

import com.tngtech.archunit.core.importer.ImportOption;
import com.tngtech.archunit.junit.AnalyzeClasses;
import com.tngtech.archunit.junit.ArchTest;
import com.tngtech.archunit.lang.ArchRule;

/** Conventions for test code: what may run in the unit phase. */
@AnalyzeClasses(packagesOf = TestConventionsTest.class, importOptions = ImportOption.OnlyIncludeTests.class)
class TestConventionsTest {

    static final ArchRule UNIT_TESTS_NEED_NO_DOCKER = noClasses()
            .that()
            .haveSimpleNameEndingWith("Test")
            .should()
            .beAnnotatedWith("org.springframework.boot.test.context.SpringBootTest")
            .orShould()
            .dependOnClassesThat()
            .resideInAPackage("org.testcontainers..")
            .orShould()
            .dependOnClassesThat()
            .haveSimpleName("TestcontainersConfiguration")
            .because("T-01: *Test classes run in the fast check without Docker. A test that needs the full context"
                    + " or a container is an integration test: rename it to *IT");

    @ArchTest
    static final ArchRule t01 = UNIT_TESTS_NEED_NO_DOCKER;
}
