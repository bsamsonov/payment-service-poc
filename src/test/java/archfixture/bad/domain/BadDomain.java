package archfixture.bad.domain;

import archfixture.bad.application.BadUseCase;
import org.springframework.stereotype.Component;

/** Violates H-01 (Spring in the domain) and H-12 (cycle with application). */
@Component
public class BadDomain {
    BadUseCase useCase;
}
