;;; depcheck.lisp

(defpackage #:depcheck
  (:use #:cl))

(in-package #:depcheck)

(defvar *direct-dependencies* nil)

(defun load-asdf-system-table (file)
  (let ((table (make-hash-table :test 'equalp)))
    (with-open-file (stream file)
      (loop for line = (read-line stream nil)
            while line do
            (let ((pathname
                   (merge-pathnames line
                                    file)))
              (setf (gethash (pathname-name pathname) table)
                    (truename pathname)))))
    table))

(defvar *systems* nil)

(defun real-system-name (name)
  (setf name (string name))
  (subseq name 0 (position #\/ name)))

(defun system-finder (name)
  (when *systems*
    (gethash (real-system-name name) *systems*)))

(defun sbcl-contrib-p (name)
  (and (<= 3 (length name))
       (string= name "sb-" :end1 3)))

(defun dependency-list-dependency (list)
  (ecase (first list)
    (:version (second list))
    (:feature (third list))))

(defun normalize-dependency (name)
  (cond ((and (consp name)
              (keywordp (first name)))
         (string-downcase (dependency-list-dependency name)))
        ((or (symbolp name) (stringp name))
         (string-downcase name))
        (t (error "Don't know how to normalize ~S" name))))

(defun make-hook (old-hook system-name)
  (lambda (fun form env)
    (when (and (consp form)
               (eq (first form) 'asdf:defsystem)
               (string-equal (second form) system-name))
      (let ((deps (getf (cddr form) :depends-on))
            (prereqs (getf (cddr form) :defsystem-depends-on))
            (weak (getf (cddr form) :weakly-depends-on)))
        (setf deps (append deps prereqs weak))
        (setf *direct-dependencies* (mapcar 'normalize-dependency deps))))
    (funcall old-hook fun form env)))

(defvar *in-find-system* nil)
(defvar *implied-dependencies* nil)

(defvar *load-op-wrapper*
  '(defmethod asdf:operate :around ((op (eql 'asdf:load-op)) system
                                    &key &allow-other-keys)
    (cond (*in-find-system*
           (push (asdf::coerce-name system) *implied-dependencies*)
           (let ((*in-find-system* nil))
             (call-next-method)))
          (t
           (call-next-method)))))

(defvar *metadata-required-p* nil)

(defun check-system-metadata (system)
  (when *metadata-required-p*
    (flet ((check-attribute (fun description)
             (let ((value (funcall fun system)))
               (cond ((not value)
                      (error "Missing ~A for system ~A"
                             description
                             (asdf:component-name system)))
                     ((and (stringp value) (zerop (length value)))
                      (error "Empty ~A for system ~A"
                             description
                             (asdf:component-name system))))
               (when (and (stringp value) (zerop (length value)))))))
      (check-attribute 'asdf:system-description :description)
      ;; Not yet
      ;;(check-attribute 'asdf:system-license :license)
      (check-attribute 'asdf:system-author :author))))

(defun compute-dependencies (system-file system-name)
  (let* ((asdf:*system-definition-search-functions*
          (list #-asdf3 'asdf::sysdef-find-asdf
                'system-finder))
         (dependencies nil)
         (*direct-dependencies* nil)
         (*macroexpand-hook* (make-hook *macroexpand-hook* system-name)))
    (let ((*implied-dependencies* nil)
          (*in-find-system* t))
      (check-system-metadata (asdf:find-system system-file))
      (setf dependencies *implied-dependencies*))
    (asdf:oos 'asdf:load-op system-name)
    (setf dependencies
          (remove-duplicates (append *direct-dependencies* dependencies)
                             :test #'equalp))
    (sort (remove-if #'sbcl-contrib-p dependencies) #'string<)))

(defun magic (system-file system trace-file)
  (handler-bind ((sb-ext:defconstant-uneql #'continue))
    (with-open-file (stream trace-file :direction :output
                            :if-exists :supersede)
      (format stream "~A~{ ~A~}~%"
              system (compute-dependencies system-file system)))))

(defun main (argv)
  (setf *print-pretty* nil)
  (sb-posix:setenv "SBCL_HOME"
                   (load-time-value
                    (directory-namestring sb-int::*core-string*))
                   1)
  (sb-posix:setenv "CC" "gcc" 1)
  (eval *load-op-wrapper*)
  (destructuring-bind (index project system dependency-file errors-file
                             &optional *metadata-required-p*)
      (rest argv)
    (setf *systems* (load-asdf-system-table index))
    (with-open-file (*error-output* errors-file
                                    :if-exists :supersede
                                    :direction :output)
      (unless (sb-posix:getenv "DEPCHECK_DEBUG")
        (sb-ext:disable-debugger))
      (unwind-protect
           (magic project system dependency-file)
        (ignore-errors (close *error-output*))))
    (when (probe-file dependency-file)
      (delete-file errors-file))))

