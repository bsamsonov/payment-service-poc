package archfixture.bad;

import org.springframework.boot.test.context.SpringBootTest;

/** Violates T-01 (full context in a *Test class). Has no test methods, so it never runs. */
@SpringBootTest
class BadContextTest {}
