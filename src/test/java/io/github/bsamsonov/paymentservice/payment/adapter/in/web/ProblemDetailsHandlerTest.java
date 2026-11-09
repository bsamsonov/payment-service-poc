package io.github.bsamsonov.paymentservice.payment.adapter.in.web;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.BDDMockito.given;

import io.github.bsamsonov.paymentservice.payment.application.CreatePaymentUseCase;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.system.CapturedOutput;
import org.springframework.boot.test.system.OutputCaptureExtension;
import org.springframework.boot.webmvc.test.autoconfigure.WebMvcTest;
import org.springframework.http.HttpStatus;
import org.springframework.http.MediaType;
import org.springframework.test.context.bean.override.mockito.MockitoBean;
import org.springframework.test.web.servlet.assertj.MockMvcTester;

/** The base error handling of the web adapter; the problem types of spec 001 are tested with their tasks. */
@WebMvcTest(PaymentsController.class)
@ExtendWith(OutputCaptureExtension.class)
class ProblemDetailsHandlerTest {

    private static final String VALID_REQUEST = """
            {"amount":1999,"currency":"USD","paymentMethodId":"pm_card_visa","externalReference":"order-1"}""";

    @Autowired
    private MockMvcTester mvc;

    @MockitoBean
    private CreatePaymentUseCase createPayment;

    @Test
    @DisplayName("an unexpected error is a 500 problem without internals, logged once with its stack trace")
    void unexpectedErrorIsA500Problem(CapturedOutput output) {
        given(createPayment.create(any())).willThrow(new IllegalStateException("connection pool secret-detail"));

        assertThat(mvc.post()
                        .uri("/api/v1/payments")
                        .contentType(MediaType.APPLICATION_JSON)
                        .content(VALID_REQUEST))
                .hasStatus(HttpStatus.INTERNAL_SERVER_ERROR)
                .hasContentType(MediaType.APPLICATION_PROBLEM_JSON)
                .bodyText()
                .doesNotContain("secret-detail");
        assertThat(output.getOut()).containsOnlyOnce("Unexpected error");
        assertThat(output.getOut()).contains("java.lang.IllegalStateException: connection pool secret-detail");
    }

    @Test
    @DisplayName("an error raised before a controller is chosen is a problem too: 415, 405, 404")
    void errorBeforeAControllerIsChosenIsAProblem() {
        assertThat(mvc.post()
                        .uri("/api/v1/payments")
                        .contentType(MediaType.TEXT_PLAIN)
                        .content("amount=1999"))
                .hasStatus(HttpStatus.UNSUPPORTED_MEDIA_TYPE)
                .hasContentType(MediaType.APPLICATION_PROBLEM_JSON);
        assertThat(mvc.delete().uri("/api/v1/payments/{id}", "01a1bd8f-e12a-7ccd-8537-f7f22d5bb92d"))
                .hasStatus(HttpStatus.METHOD_NOT_ALLOWED)
                .hasContentType(MediaType.APPLICATION_PROBLEM_JSON);
        assertThat(mvc.get().uri("/api/v1/no-such-resource"))
                .hasStatus(HttpStatus.NOT_FOUND)
                .hasContentType(MediaType.APPLICATION_PROBLEM_JSON);
    }

    @Test
    @DisplayName("an endpoint not implemented yet answers 501 as a problem")
    void notImplementedEndpointIsA501Problem() {
        assertThat(mvc.get().uri("/api/v1/payments/{id}", "01a1bd8f-e12a-7ccd-8537-f7f22d5bb92d"))
                .hasStatus(HttpStatus.NOT_IMPLEMENTED)
                .hasContentType(MediaType.APPLICATION_PROBLEM_JSON);
    }
}
