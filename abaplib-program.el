;;; abaplib_programs.el --- ABAP programs            -*- lexical-binding: t; -*-

;; Copyright (C) 2018  Marvin Qian

;; Author: Marvin Qian <qianmarv@gmail.com>
;; Keywords: 

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
;;==============================================================================
;; Retrieve Program Source From Server
;; TODO Consider ETag
;; 1. Get Local Source Information (ETag)
;; 2. Retrieve with ETag in Header
;; 3. If Got 304 - Not Modified ==> Open Local Source File
;; 4. If Got 200 => Overwrite On Current Implementation
;; 4.1 => Overwrite Metadata File
;; TODO 4.2.1 => If Local File Exist => Compare (EDiff) and Prompt to User
;; 4.2.2 => No Local File => Directly Write to Local
;;==============================================================================

(defvar-local abap-program--name nil
  "ABAP program name")

(defvar-local abap-program--properties-cache nil
  "ABAP program properties")

(defun abap-program--get-properties ()
  " Get program properties"
  (unless abap-program--name
    (error "Program is nil"))
  (unless abap-program--properties-cache
    (let ((prop-file (expand-file-name (concat abap-program--name ".prog.json")
                                       (abaplib-get-project-cache-dir))))
      (when (file-exists-p prop-file)
        (setq abap-program--properties-cache (json-read-file prop-file)))))
  abap-program--properties-cache)

(defun abap-program--get-property (key)
  " Get program property by key"
  (alist-get key (abap-program--get-properties)))

(defun abap-program--set-properties(properties)
  " Get metadata from cache"
  (let ((prop-file (expand-file-name (concat abap-program--name ".prog.json")
                                     (abaplib-get-project-cache-dir))))
    (setq abap-program--properties-cache properties)
    (abaplib-util-jsonize-to-file (abap-program--get-properties) prop-file)))

(defun abap-program--set-property (key value)
  "Set property"
  (abap-program--set-properties
   (abaplib-util-upsert-alists (abap-program--get-properties) (cons key value))))

(defun abap-program--parse-metadata (xml-node)
  (let* ((program-props)
         (type (xml-get-attribute xml-node 'type))
         (version (xml-get-attribute xml-node 'version))
         (sourceUri (xml-get-attribute xml-node 'sourceUri))
         (etag))
    (let ((links (xml-get-children xml-node 'link)))
      (dolist (link links)
        (when (string= (xml-get-attribute link 'type) "text/plain")
          (setq etag (xml-get-attribute link 'etag))
          (return))))
    (setq program-props (append (list `(type . ,type)
                                      `(version . ,version)
                                      `(source-uri . ,sourceUri)
                                      `(etag . ,etag))))))

(defun abap-program--get-directory ()
  "Get program source directory"
  (let* ((major-type-dir (expand-file-name "Source Code"
                                           (abaplib-project-get-property 'path)))
         (minor-type-dir (expand-file-name "Programs"
                                           major-type-dir)))
    (unless (file-exists-p major-type-dir)
      (make-directory major-type-dir))
    (unless (file-exists-p minor-type-dir)
      (make-directory minor-type-dir))
    minor-type-dir))

(defun abap-program--get-source-file ()
  (expand-file-name (concat abap-program--name ".prog.abap")
                    (abap-program--get-directory)))

(defun abap-program--retrieve-properties (program-name &optional etag)
  "Retrieve program metadata from server"
  ;; TODO Problebly not necessary to match etag as ADT always retrieve metadata
  ;;      Not sure whether etag will be verified in server side.
  (let ((url (abaplib-get-project-api-url (concat "/sap/bc/adt/programs/programs/"
                                                  program-name))))
    (abaplib--rest-api-call
     url
     (lambda (&rest rest)
       (let* ((response-data (cl-getf rest :data))
              (response (cl-getf rest :response))
              (status-code (request-response-status-code response))
              (metadata-etag (request-response-header response "ETag"))
              (properties))
         (unless (eq status-code 304) ;; Not modified
           (abap-program--set-properties (append
                                          (abap-program--parse-metadata response-data)
                                          (list `(metadata-etag . ,metadata-etag))))

           (abap-program--set-properties properties)
           (message "Program metadata retrieved."))))
     :parser 'abaplib-util-xml-parser
     :headers (list `("If-None-Match" . ,etag)))))

(defun abap-program--retrieve-source (program-name &optional etag)
  "Retrieve program source from server"
  (let ((url (abaplib-get-project-api-url (format
                                           "/sap/bc/adt/programs/programs/%s/source/main"
                                           program-name))))
    (abaplib--rest-api-call
     url
     (lambda (&rest rest)
       (let ((response-data (cl-getf rest :data))
             (status-code (request-response-status-code (cl-getf rest :response))))
         (if (eq status-code 304)
             (message "Program source remain unchanged in server.")
           (write-region response-data nil (abap-program--get-source-file))
           (message "Program source retrieved from server and overwrite local."))))
     :parser 'abaplib-util-sourcecode-parser
     :headers (list `("If-None-Match" . ,etag)
                    '("Content-Type" . "plain/text")))))


(defun abap-program-retrieve(&optional program-name)
  ;; Retrieve metadata
  (let ((program-name (or program-name
                          abap-program--name)))
    (setq abap-program--name program-name)

    (let ((source-etag (abap-program--get-property 'etag))
          (metadata-etag (abap-program--get-property 'metadata-etag)))
      (abap-program--retrieve-properties program-name metadata-etag)
      (abap-program--retrieve-source program-name source-etag))))

(defun abap-program-check-syntax (prog-name source &optional version )
  "Check ABAP program syntax based on local unsubmitted source"
  (let* ((version (or version "active"))
         (adtcore-uri (concat "/sap/bc/adt/programs/programs/" prog-name))
         (chkrun-uri  (concat adtcore-uri "/source/main"))
         (chkrun-content (base64-encode-string source))
         (post-data (abaplib-core-check-syntax-template
                     adtcore-uri
                     chkrun-uri version chkrun-content)))
    ;; before post
    ;; (message post-data)
    (abaplib-service-call
     (abaplib-service-get-uri 'checkrun)
     (lambda (&rest rest)
       (let* ((check-report (xml-get-children (cl-getf rest :data) 'checkReport))
              (message-list (xml-get-children (car check-report) 'checkMessageList))
              (messages (xml-get-children (car message-list) 'checkMessage)))
         (abaplib-core-check-show-message messages)
         ))
     :parser 'abaplib-util-xml-parser
     :type "POST"
     :data post-data
     :headers `(("Content-Type" . "application/vnd.sap.adt.checkobjects+xml"))
     )
    ))

(defun abap-program-submit()
  (let ((prog-name   (abaplib-object-get-name))
        (prog-source (buffer-substring-no-properties (point-min) (point-max)))
        (lock-handle (abaplib-core-lock)))
    (abaplib-service-call
     (abaplib-service-get-uri 'save-program-source prog-name)
     (lambda (&rest rest)
       (let* ((response (cl-getf rest :response))
              (ETag (request-response-header response "ETag")))
         (message (format "Succeed with ETAG:%s" ETag))
         (abaplib-core-unlock lock-handle)))
     :type "PUT"
     :data prog-source
     :headers `(("Content-Type" . "text/plain"))
     :params `(("lockHandle" . ,lock-handle))
     )))
(provide 'abaplib-program)
;;; abaplib_programs.el ends here