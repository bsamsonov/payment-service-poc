package io.github.bsamsonov.paymentservice;

import static com.tngtech.archunit.core.domain.JavaClass.Predicates.resideInAPackage;
import static com.tngtech.archunit.core.domain.JavaClass.Predicates.resideInAnyPackage;
import static com.tngtech.archunit.lang.syntax.ArchRuleDefinition.classes;
import static com.tngtech.archunit.lang.syntax.ArchRuleDefinition.noClasses;
import static com.tngtech.archunit.lang.syntax.ArchRuleDefinition.noMethods;
import static com.tngtech.archunit.library.dependencies.SlicesRuleDefinition.slices;

import com.tngtech.archunit.lang.ArchRule;

/**
 * Hexagonal rules for one module, for example {@code paymentservice.payment}. The module root is a parameter so that
 * the same rules run against every module and against the deliberately broken fixtures in {@code archfixture.bad} (see
 * {@code HexagonRulesSelfTest}).
 *
 * <p>Every {@code because} says where the code belongs: fix a violation by moving code, never by editing a rule.
 */
final class HexagonRules {

    private final String root;

    HexagonRules(String root) {
        this.root = root;
    }

    private String p(String relative) {
        return root + "." + relative;
    }

    /** H-01. */
    ArchRule domainIsPlainJava() {
        return classes()
                .that()
                .resideInAPackage(p("domain.."))
                .should()
                .onlyDependOnClassesThat()
                .resideInAnyPackage(p("domain.."), "java..", "org.jspecify..")
                .because("H-01: the domain is plain Java. Put the technology (Spring, JPA, Jackson, ids, clocks) in an"
                        + " adapter or in application and pass plain values in; do not extend the allow-list");
    }

    /** H-02. */
    ArchRule applicationKnowsNoAdaptersAndNoTechnology() {
        return noClasses()
                .that()
                .resideInAPackage(p("application.."))
                .should()
                .dependOnClassesThat()
                .resideInAnyPackage(
                        p("adapter.."),
                        p("config.."),
                        "org.springframework.web..",
                        "org.springframework.http..",
                        "org.springframework.data..",
                        "org.springframework.jdbc..",
                        "jakarta.persistence..",
                        "jakarta.servlet..",
                        "org.hibernate..",
                        "java.sql..",
                        "tools.jackson..",
                        "com.fasterxml.jackson..")
                .because("H-02: use cases reach the outside world only through ports. Declare what you need as an"
                        + " interface in application.port and implement it in adapter.out; HTTP, SQL and JSON types"
                        + " stay in adapters");
    }

    /** H-03. */
    ArchRule portsSpeakDomainLanguage() {
        return classes()
                .that()
                .resideInAPackage(p("application.port.."))
                .should()
                .onlyDependOnClassesThat()
                .resideInAnyPackage(p("domain.."), p("application.port.."), "java..", "org.jspecify..")
                .because("H-03: a port is declared in domain terms. Types such as Pageable, ResponseEntity, JPA"
                        + " entities or provider DTOs must be converted inside the adapter that implements the port");
    }

    /** H-04. */
    ArchRule webDoesNotUsePorts() {
        return noClasses()
                .that()
                .resideInAPackage(p("adapter.in.."))
                .should()
                .dependOnClassesThat()
                .resideInAPackage(p("application.port.."))
                .because("H-04: an inbound adapter calls a use case. Reading or writing through a port from a"
                        + " controller puts orchestration into the adapter; move it to a use case in application");
    }

    /** H-05. */
    ArchRule adaptersDoNotDependOnEachOther() {
        return slices().matching(p("adapter.(*).(*).."))
                .should()
                .notDependOnEachOther()
                .because("H-05: adapters never use each other. Pass the data through a use case and a port, or move"
                        + " shared code into application or domain");
    }

    /** H-06. */
    ArchRule adapterClassesAreNotPublic() {
        return classes()
                .that()
                .resideInAPackage(p("adapter.."))
                .and()
                .resideOutsideOfPackages(p("adapter.in.web.api.."), p("adapter.in.web.model.."))
                .should()
                .notBePublic()
                .because("H-06: adapters are reached only through ports or HTTP, so entities, mappers and clients"
                        + " cannot leak. Keep the class package-private and expose a port instead of making it"
                        + " public");
    }

    /** H-07. */
    ArchRule generatedApiStaysInWebAdapter() {
        return noClasses()
                .that()
                .resideOutsideOfPackage(p("adapter.in.web.."))
                .should()
                .dependOnClassesThat()
                .resideInAnyPackage(p("adapter.in.web.api.."), p("adapter.in.web.model.."))
                .because("H-07: generated API types are the HTTP contract, not the model. Map them to a command or a"
                        + " domain type in adapter.in.web");
    }

    /** H-08. */
    ArchRule endpointsComeFromTheContract() {
        return noMethods()
                .that()
                .areDeclaredInClassesThat()
                .resideOutsideOfPackage(p("adapter.in.web.api.."))
                .should()
                .beMetaAnnotatedWith("org.springframework.web.bind.annotation.RequestMapping")
                .because("H-08: every endpoint is declared in api/openapi.yaml and generated. Add the operation to"
                        + " the contract (with a spec change) and implement the generated interface; do not"
                        + " hand-write mapping annotations");
    }

    /** H-09. */
    ArchRule jpaStaysInPersistenceAdapter() {
        return noClasses()
                .that()
                .resideOutsideOfPackage(p("adapter.out.persistence.."))
                .should()
                .dependOnClassesThat()
                .resideInAnyPackage("jakarta.persistence..", "org.hibernate..")
                .because("H-09: JPA entities and queries live in adapter.out.persistence; return domain types"
                        + " through a port");
    }

    /** H-10. */
    ArchRule webStereotypesStayInWebAdapter() {
        return classes()
                .that()
                .areMetaAnnotatedWith("org.springframework.stereotype.Controller")
                .or()
                .areMetaAnnotatedWith("org.springframework.web.bind.annotation.ControllerAdvice")
                .should()
                .resideInAPackage(p("adapter.in.web.."))
                .because("H-10: HTTP handling belongs to adapter.in.web");
    }

    /** H-11. */
    ArchRule onlyTheApplicationClassSeesConfig() {
        return noClasses()
                .that(resideInAnyPackage(p("domain.."), p("application.."), p("adapter..")))
                .should()
                .dependOnClassesThat(resideInAPackage(p("config..")))
                .because("H-11: config wires the application and nothing depends on it. Inject the value or the"
                        + " bean type you need instead of a configuration class");
    }

    /** H-12. */
    ArchRule noPackageCycles() {
        return slices().matching(p("(*).."))
                .should()
                .beFreeOfCycles()
                .because("H-12: the layers of a module form a one-way dependency chain; break the cycle by moving the"
                        + " shared type inwards (to domain or application)");
    }
}
