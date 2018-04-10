;;; abaplib-class.el --- ABAP Class -*- lexical-binding: t; -*-

;; Copyright (C) 2018  Marvin Qian

;; Author: Marvin Qian <qianmarv@gmail.com>
;; Keywords: ABAP source, class

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:

;; 

;;; Code:

(require 'abaplib-core)
;==============================================================================

(defvar-local abaplib-class--name nil
  "ABAP class name")

(defvar-local abaplib-class--properties-cache nil
  "ABAP class properties")

(defconst abaplib-class--uri-prefix "/sap/bc/adt/oo/classes")

(defvar abaplib-class--uri nil)
;; (defvar abaplib-class--source-uri nil)

(defconst abaplib-class--folder "Classes")

;; FIXME 1. Add programe name to metdata file
;;       2. verify program name while retrieve from cache
(defun abaplib-class--get-properties (&optional class-name)
  " Get program properties"
  (let* ((class-name (or class-name
                        abaplib-class--name))
         (class-dir (expand-file-name class-name (abaplib-class--get-root-directory))))
    (unless class-name
      (error "Class is nil"))
    (unless (file-directory-p class-dir)
      (make-directory class-dir))
    (unless abaplib-class--properties-cache
      (let ((prop-file (expand-file-name "properties.json" class-dir)))
        (when (file-exists-p prop-file)
          (setq abaplib-class--properties-cache (json-read-file prop-file)))))
    abaplib-class--properties-cache))

(defun abaplib-class--get-root-directory ()
  (let* ((source-dir (expand-file-name abaplib-core--folder-S (abaplib-get-project-path)))
         (class-dir  (expand-file-name abaplib-class--folder source-dir )))
    (unless (file-directory-p source-dir)
      (make-directory source-dir))
    (unless (file-directory-p class-dir)
      (make-directory class-dir))))

(defun abaplib-class--get-property (key &optional class-name)
  " Get program property by key"
  (alist-get key (abaplib-class--get-properties class-name)))

(defun abaplib-class--set-properties(properties)
  " Get metadata from cache"
  (let ((prop-file (expand-file-name "properties.json" class-dir)))
    (setq abaplib-class--properties-cache properties)
    (abaplib-util-jsonize-to-file (abaplib-class--get-properties) prop-file)))

;; (defun abaplib-class--set-property (key value)
;;   "Set property"
;;   (abaplib-class--set-properties
;;    (abaplib-util-upsert-alists (abaplib-class--get-properties) (cons key value))))

(defun abaplib-class--parse-metadata (xml-node)
  (let* ((adtcore-type (xml-get-attribute xml-node 'type))
         (type-list (split-string adtcore-type "/"))
         (type (car type-list))
         (subtype (nth 1 type-list))
         (name (xml-get-attribute xml-node 'name))
         (description (xml-get-attribute xml-node 'description))
         (version (xml-get-attribute xml-node 'version))
         ;; (sourceUri (xml-get-attribute xml-node 'sourceUri))
         ;; (links (xml-get-children xml-node 'link))
         (package-node (car (xml-get-children xml-node 'packageRef)))
         (package (xml-get-attribute package-node 'name))
         (etag))
    (dolist (link links)
      (when (string= (xml-get-attribute link 'type) "text/plain")
        (setq etag (xml-get-attribute link 'etag))
        (return)))
    `((name . ,name)
      (description . ,description)
      (type . ,type)
      (subtype . ,subtype)
      (version . ,version)
      (source-uri . ,sourceUri)
      (package . ,package)
      (etag . ,etag))))

(defun abaplib-class--retrieve-properties-sync ()
  "Retrieve class metadata from server"
  (let* ((etag (abaplib-class--get-property 'metadata-etag))
         (class-name abaplib-class--name)
         (url (abaplib-get-project-api-url abaplib-class--uri))
         (response (abaplib--rest-api-call url
                                           nil
                                           :parser 'abaplib-util-xml-parser
                                           :headers (list `("If-None-Match" . ,etag))))
         (data (request-response-data response))
         (status-code (request-response-status-code response))
         (metadata-etag (request-response-header response "ETag")))

    (unless (eq status-code 304) ;; Not modified
      (abaplib-class--set-properties (append
                                      (abaplib-class--parse-metadata response-data)
                                      (list `(metadata-etag . ,metadata-etag))))
      (message "class metadata refreshed."))))

;; (defun abaplib-class--buffer-get-create (class-name)
;;   (get-buffer-create (format "*(Server) %s *" class-name)))

;; (defun abaplib-class--retrieve-source (etag &optional target-file)
;;   "Retrieve program source from server"
;;   (let* ((class-name abaplib-class--name)
;;          (url (abaplib-get-project-api-url abaplib-class--source-uri)))
;;     (abaplib--rest-api-call
;;      url
;;      (lambda (&rest rest)
;;        (let ((response-data (cl-getf rest :data))
;;              (status-code (request-response-status-code (cl-getf rest :response))))
;;          (if (eq status-code 304)
;;              (message "Program source remain unchanged in server.")
;;            (if target-file
;;                (write-region response-data nil (abaplib-class--get-source-file class-name))
;;              (let ((buffer (abaplib-class--buffer-get-create class-name)))
;;                (set-buffer buffer)
;;                (erase-buffer)
;;                (goto-char (point-min))
;;                (insert response-data)
;;                (switch-to-buffer buffer)))
;;            (message "Program source retrieved from server and overwrite local."))))
;;      :parser 'abaplib-util-sourcecode-parser
;;      :headers (list `("If-None-Match" . ,etag)
;;                     '("Content-Type" . "plain/text")))))

(defun abaplib-class-do-retrieve(abap-object)
  "Retrieve source code"
  ;; 1. Retrieve/refresh metadata in synchronouse
  ;; 2. Get source uri
  ;; 3. Retrieve source in asynchronouse
  ;; 4. Open source buffer
  ;; (abaplib-class--init abap-object)
  (abaplib-class--init abap-object)
  (abaplib-class--retrieve-properties-sync)
  (let ((metadata-etag (abaplib-class--get-property 'metadata-etag)))))

;; (let ((source-etag (abaplib-class--get-property 'etag))
;;       (metadata-etag (abaplib-class--get-property 'metadata-etag))
;;       (source-file (abaplib-class--get-source-file abaplib-class--name)))
;;   (abaplib-class--retrieve-properties metadata-etag)
;;   (abaplib-class--retrieve-source source-etag source-file))

;; (defun abaplib-class-do-check(abap-object)
;;   "Check syntax for program source
;;   TODO check whether source changed since last retrieved from server
;;        Not necessary to send the source code to server if no change."
;;   (abaplib-class--init abap-object)
;;   (let ((version (abaplib-class--get-property 'version))
;;         (adtcore-uri abaplib-class--uri)
;;         (chkrun-uri  abaplib-class--source-uri)
;;         (chkrun-content (base64-encode-string (buffer-substring-no-properties
;;                                                (point-min)
;;                                                (point-max)))))
;;     (abaplib-core-check-post version adtcore-uri chkrun-uri chkrun-content)))

;; (defun abaplib-class-do-submit(abap-object)
;;   "Submit source to server

;;    TODO Check source in server side if current source was changed based on an old version
;;    The submission should be cancelled"
;;   (abaplib-class--init abap-object)
;;   (let* ((source (buffer-substring-no-properties (point-min) (point-max)))
;;          (csrf-token (abaplib-core-get-csrf-token))
;;          (lock-handle (abaplib-core-lock-sync abaplib-class--uri csrf-token)))
;;     (abaplib--rest-api-call
;;      (abaplib-get-project-api-url abaplib-class--source-uri)
;;      (lambda (&rest rest)
;;        (let* ((response (cl-getf rest :response))
;;               (ETag (request-response-header response "ETag")))
;;          (abaplib-class--retrieve-properties)
;;          (message "program submit to server success.")))
;;      :type "PUT"
;;      :data source
;;      :headers `(("Content-Type" . "text/plain")
;;                 ("x-csrf-token" . ,csrf-token))
;;      :params `(("lockHandle" . ,lock-handle))
;;      )))

;; (defun abaplib-class-do-activate(abap-object)
;;   "Activate source in server"
;;   (abaplib-class--init abap-object)
;;   (let* ((adtcore-name abaplib-class--name)
;;          (adtcore-uri abaplib-class--uri))
;;     (abaplib-core-activate-post adtcore-name adtcore-uri)))


(defun abaplib-class--init (abap-object)
  ;; (message "called abaplib-class--init with: %s" abap-object)
  (let* ((class-name (alist-get 'name abap-object))
         (type (alist-get 'type abap-object))
         (sub-type (or (alist-get 'subtype abap-object)
                       (abaplib-class--get-property 'subtype class-name)))
         (uri-prefix abaplib-class--uri-prefix))
    (setq abaplib-class--name class-name)
    (setq abaplib-class--uri (concat uri-prefix "/" class-name))))


(provide 'abaplib-class)
;;; abaplib-class.el ends here