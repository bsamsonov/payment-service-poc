package archfixture.bad.config;

import org.hibernate.validator.HibernateValidator;
import org.springframework.web.bind.annotation.RestController;

/** Violates H-09 (Hibernate outside the persistence adapter) and H-10 (controller outside the web adapter). */
@RestController
public class BadConfig {
    HibernateValidator validator;
}
