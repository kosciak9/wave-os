(define-module (development-caddy bounded-http)
  #:use-module (web server)
  #:use-module (web request)
  #:use-module (web response)
  #:use-module (srfi srfi-9)
  #:use-module (srfi srfi-11)
  #:use-module (rnrs bytevectors)
  #:export (bounded-http oversized-body?))

;; This is deliberately opaque to the application: it is never the body of
;; an accepted request, and therefore cannot cause read-request-body to run.
(define-record-type <oversized-body>
  (make-oversized-body)
  oversized-body?)
(define oversized (make-oversized-body))

(define-record-type <bounded-server>
  (make-bounded-server socket max-body)
  bounded-server?
  (socket bounded-server-socket)
  (max-body bounded-server-max-body))

(define* (open-bounded #:key (host "127.0.0.1") (port 8080) (max-body 16384))
  (let* ((socket (socket PF_INET SOCK_STREAM 0))
         (address (inet-pton AF_INET host)))
    (setsockopt socket SOL_SOCKET SO_REUSEADDR 1)
    (bind socket AF_INET address port)
    (listen socket 32)
    (make-bounded-server socket max-body)))

(define (timeout! socket)
  (setsockopt socket SOL_SOCKET SO_RCVTIMEO '(5 . 0))
  (setsockopt socket SOL_SOCKET SO_SNDTIMEO '(5 . 0)))

(define (bad-request! client)
  (let* ((response (build-response #:version '(1 . 0) #:code 400
                                   #:headers '((content-length . 11)
                                               (content-type . (text/plain)))))
         (response (write-response response client)))
    (write-response-body response (string->utf8 "bad request\n"))
    (force-output client)))

(define (read-bounded server)
  (let* ((accepted (accept (bounded-server-socket server)))
         (client (car accepted)))
    (timeout! client)
    (catch #t
      (lambda ()
         (let* ((request (read-request client))
                (length (request-content-length request)))
           (if (pair? (request-transfer-encoding request))
               (throw 'malformed-transfer-encoding)
               (if (and length (> length (bounded-server-max-body server)))
                   (values client request oversized)
                   (values client request (read-request-body request))))))
      (lambda _
        (dynamic-wind
          (lambda () #t)
          (lambda () (bad-request! client))
          (lambda () (false-if-exception (close-port client))))
        (values #f #f #f)))))

(define (write-bounded server client response body)
  (dynamic-wind
    (lambda () #t)
    (lambda ()
      (let ((response (write-response response client)))
        (when body (write-response-body response body))
        (force-output client)))
    (lambda () (false-if-exception (close-port client)))))

(define (close-bounded server)
  (close-port (bounded-server-socket server)))

(define bounded-http
  (make-server-impl 'bounded-http open-bounded read-bounded
                    write-bounded close-bounded))
