package archfixture.app.alpha;

import archfixture.app.beta.Beta;

/** Violates M-02 (cycle between modules alpha and beta). */
public class Alpha {
    Beta beta;
}
