package archfixture.app.beta;

import archfixture.app.alpha.Alpha;

/** Violates M-02 (cycle between modules alpha and beta). */
public class Beta {
    Alpha alpha;
}
