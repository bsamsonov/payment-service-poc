package io.github.bsamsonov.paymentservice;

import static com.tngtech.archunit.lang.syntax.ArchRuleDefinition.noClasses;
import static com.tngtech.archunit.library.dependencies.SlicesRuleDefinition.slices;

import com.tngtech.archunit.lang.ArchRule;

/**
 * Rules for the module layout: code lives in {@code <root>.<module>} packages ({@code payment}, later {@code refund}
 * and {@code stripe}), and each domain module is hexagonal inside (see {@link HexagonRules}). Like
 * {@link HexagonRules}, the root is a parameter so that the rules also run against fixtures.
 *
 * <p>M-02 stands in for Spring Modulith {@code ApplicationModules.verify()} until a second module exists.
 */
final class ModuleRules {

    private final String root;
    private final String applicationClass;

    ModuleRules(String root, String applicationClass) {
        this.root = root;
        this.applicationClass = applicationClass;
    }

    /** M-01. */
    ArchRule everyClassBelongsToAModule() {
        return noClasses()
                .that()
                .doNotHaveFullyQualifiedName(applicationClass)
                .and()
                .doNotHaveSimpleName("package-info")
                .should()
                .resideInAnyPackage(
                        root, root + ".domain..", root + ".application..", root + ".adapter..", root + ".config..")
                .because("M-01: code lives in a module package such as payment, with its own domain, application,"
                        + " adapter and config layers inside. Only the application class stays in the root package;"
                        + " never add layer packages at the root. A new module needs the owner's decision");
    }

    /** M-02. */
    ArchRule modulesAreFreeOfCycles() {
        return slices().matching(root + ".(*)..")
                .should()
                .beFreeOfCycles()
                .because("M-02: modules depend on each other one way only (for example refund -> payment, stripe ->"
                        + " payment). Break the cycle with a port owned by the module that is depended upon");
    }
}
