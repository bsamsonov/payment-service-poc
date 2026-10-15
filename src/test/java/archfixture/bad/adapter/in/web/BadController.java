package archfixture.bad.adapter.in.web;

import archfixture.bad.adapter.out.persistence.BadEntity;
import archfixture.bad.application.port.BadPort;
import org.springframework.web.bind.annotation.GetMapping;

/** Violates H-04 (port in a controller), H-05 (another adapter), H-08 (hand-written mapping). */
class BadController {
    BadPort port;
    BadEntity entity;

    @GetMapping("/bad")
    String bad() {
        return "bad";
    }
}
