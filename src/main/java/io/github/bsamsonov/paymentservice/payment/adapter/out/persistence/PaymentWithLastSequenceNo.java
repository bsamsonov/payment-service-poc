package io.github.bsamsonov.paymentservice.payment.adapter.out.persistence;

/** A managed payment row and the last {@code sequence_no} of its events (0 if none), from one query. */
record PaymentWithLastSequenceNo(PaymentEntity payment, long lastSequenceNo) {}
