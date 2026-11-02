/**
 * de_inbound_email_classification
 *
 * Email service handler for inbound customer emails (SwiftParcel shipment support).
 *
 * Responsibilities:
 *   1. Create an "intake" Case from the inbound email's subject and body.
 *   2. Log the inbound email as an EmailMessage on the Case so it appears in the
 *      Case's Emails related list / activity feed.
 *   3. Attach any documents that arrived with the email (binary and text) as
 *      Files (ContentVersion) linked to the Case.
 *   4. Hand the subject, body and attached image to the SwiftParcel_Shipment_Extraction
 *      prompt template. The template analyses the text + image and returns a JSON
 *      array of shipment records ({name, mobileNumber, awbNumber, email,
 *      description}).
 *        - UC1 (single tracking screenshot): one record -> populate the intake Case.
 *        - UC2 (multi-row NDR sheet): N records -> keep the intake Case as the parent
 *          (the inbound request) and create one child Case per shipment row, each
 *          linked to the parent via ParentId.
 *   5. Reply to the sender acknowledging receipt with the Case number(s) and the
 *      AWB / shipment number(s) that were recognised.
 *
 * The prompt call is isolated behind the ShipmentExtractor seam so the handler can
 * be unit-tested without invoking Einstein at runtime (see setExtractor()).
 */
global with sharing class de_inbound_email_classification implements Messaging.InboundEmailHandler {

    // Default text used when the inbound email carries no subject/body.
    private static final String DEFAULT_SUBJECT = '(No Subject)';
    private static final String DEFAULT_BODY = '(No content provided)';

    // Developer name of the deployed Flex prompt template.
    @TestVisible
    private static final String TEMPLATE_NAME = 'SwiftParcel_Shipment_Extraction';

    // Maximum number of shipment records (child Cases in UC2) created from a single
    // inbound email, regardless of how many the extractor returns.
    private static final Integer MAX_SHIPMENTS = 10;

    /**
     * One shipment extracted from the email/image by the prompt template. Field
     * names deliberately match the JSON keys the template is instructed to emit.
     */
    public class ShipmentRecord {
        public String name;
        public String mobileNumber;
        public String awbNumber;
        public String email;
        public String description;
    }

    /** A stored inbound attachment: its ContentDocument id plus whether it is an image. */
    public class StoredFile {
        public Id contentDocumentId;
        public String fileName;
        public Boolean isImage;
    }

    /** Seam over the AI extraction so tests can stub it. */
    public interface ShipmentExtractor {
        List<ShipmentRecord> extract(String subject, String description, Id contentDocumentId);
    }

    // Injected extractor; defaults to the real prompt-template implementation.
    @TestVisible
    private static ShipmentExtractor extractor = new PromptShipmentExtractor();

    @TestVisible
    private static void setExtractor(ShipmentExtractor mock) {
        extractor = mock;
    }

    global Messaging.InboundEmailResult handleInboundEmail(
        Messaging.InboundEmail email,
        Messaging.InboundEnvelope envelope
    ) {
        Messaging.InboundEmailResult result = new Messaging.InboundEmailResult();

        try {
            String subject = String.isBlank(email.subject) ? DEFAULT_SUBJECT : email.subject;
            String description = resolveBody(email);
            String fromAddress = envelope != null && String.isNotBlank(envelope.fromAddress)
                ? envelope.fromAddress
                : email.fromAddress;

            // 1. Create the intake Case. Attach a matching Contact (by sender email)
            //    up front so it is set at insert time - the org's Case-creation flow
            //    repopulates SuppliedEmail from Contact.Email, so linking the Contact
            //    also keeps the Web Email field from being blanked out.
            Case intakeCase = new Case(
                Subject = subject,
                Description = description,
                Origin = 'Email',
                Status = 'New',
                SuppliedEmail = fromAddress,
                SuppliedName = email.fromName,
                ContactId = findContactIdByEmail(fromAddress)
            );
            insert intakeCase;

            // 2. Log the inbound email as an EmailMessage on the Case.
            logEmailMessage(email, envelope, intakeCase.Id);

            // 3. Attach any incoming documents to the Case. Keep every doc id (so the
            //    source file can be linked to child Cases) and pick the FIRST real
            //    image for the vision prompt - a spreadsheet must never be sent as
            //    the "image" input.
            List<StoredFile> storedFiles = attachDocuments(email, intakeCase.Id);
            List<Id> contentDocumentIds = new List<Id>();
            Id imageDocId = null;
            for (StoredFile sf : storedFiles) {
                contentDocumentIds.add(sf.contentDocumentId);
                if (imageDocId == null && sf.isImage) {
                    imageDocId = sf.contentDocumentId;
                }
            }

            // 3b. Convert spreadsheet/CSV attachments to text and append it to the
            //     body we hand the prompt. The prompt template is unchanged - the
            //     extra text simply rides in via the existing 'description' input.
            //     Case.Description keeps the original body only (not the dump).
            String promptDescription = buildPromptDescription(email, description);

            System.debug(LoggingLevel.INFO, 'SwiftParcel> attachments: binary='
                + (email.binaryAttachments == null ? 0 : email.binaryAttachments.size())
                + ' text=' + (email.textAttachments == null ? 0 : email.textAttachments.size())
                + ' | storedFiles=' + storedFiles.size()
                + ' | imageDocId=' + imageDocId);
            System.debug(LoggingLevel.INFO, 'SwiftParcel> promptDescription length='
                + (promptDescription == null ? 0 : promptDescription.length())
                + ' | preview=' + safePreview(promptDescription, 1000));

            // 4. Extract shipment details from the subject/body/image and apply them.
            List<Case> allCases = classifyAndPopulate(
                subject, description, promptDescription, imageDocId, intakeCase, fromAddress, contentDocumentIds
            );

            // 5. Acknowledge receipt to the sender.
            sendAcknowledgement(email, allCases);

            result.success = true;
        } catch (Exception ex) {
            // Returning success = false lets the platform bounce/retry the email
            // and surfaces the failure rather than silently dropping the message.
            System.debug(LoggingLevel.ERROR, 'de_inbound_email_classification failed: '
                + ex.getMessage() + '\n' + ex.getStackTraceString());
            result.success = false;
            result.message = 'Failed to process inbound email: ' + ex.getMessage();
        }

        return result;
    }

    /**
     * Resolves the body of the email, preferring plain text and falling back to
     * the HTML body when no plain-text part is present.
     */
    private String resolveBody(Messaging.InboundEmail email) {
        if (String.isNotBlank(email.plainTextBody)) {
            return email.plainTextBody;
        }
        if (String.isNotBlank(email.htmlBody)) {
            return email.htmlBody;
        }
        return DEFAULT_BODY;
    }

    /**
     * Creates an EmailMessage record for the inbound email and relates it to the
     * Case so the original email appears under the Case's Emails related list.
     */
    private void logEmailMessage(
        Messaging.InboundEmail email,
        Messaging.InboundEnvelope envelope,
        Id caseId
    ) {
        String fromAddress = envelope != null && String.isNotBlank(envelope.fromAddress)
            ? envelope.fromAddress
            : email.fromAddress;

        EmailMessage msg = new EmailMessage();
        msg.ParentId = caseId;
        msg.Incoming = true; // marks it as a received (inbound) email
        msg.Subject = String.isBlank(email.subject) ? DEFAULT_SUBJECT : email.subject;
        msg.FromAddress = fromAddress;
        msg.FromName = email.fromName;
        msg.ToAddress = envelope != null ? envelope.toAddress : null;
        msg.TextBody = String.isNotBlank(email.plainTextBody) ? email.plainTextBody : email.htmlBody;
        msg.HtmlBody = email.htmlBody;
        msg.MessageDate = System.now();
        msg.Status = '0'; // 0 = New

        insert msg;
    }

    /**
     * Saves both binary and text attachments from the inbound email as Files
     * (ContentVersion / ContentDocumentLink) associated with the given Case and
     * returns them in attachment order, each flagged with whether it is a real
     * image (so the caller can send the image - not a spreadsheet - to the prompt).
     */
    private List<StoredFile> attachDocuments(Messaging.InboundEmail email, Id caseId) {
        List<ContentVersion> versions = new List<ContentVersion>();

        if (email.binaryAttachments != null) {
            for (Messaging.InboundEmail.BinaryAttachment attachment : email.binaryAttachments) {
                versions.add(new ContentVersion(
                    Title = attachment.fileName,
                    PathOnClient = attachment.fileName,
                    VersionData = attachment.body
                ));
            }
        }

        if (email.textAttachments != null) {
            for (Messaging.InboundEmail.TextAttachment attachment : email.textAttachments) {
                versions.add(new ContentVersion(
                    Title = attachment.fileName,
                    PathOnClient = attachment.fileName,
                    VersionData = Blob.valueOf(attachment.body)
                ));
            }
        }

        if (versions.isEmpty()) {
            return new List<StoredFile>();
        }

        insert versions;

        Set<Id> versionIds = new Set<Id>();
        for (ContentVersion cv : versions) {
            versionIds.add(cv.Id);
        }

        // Map version -> document id. The SOQL result order is not guaranteed, so
        // we iterate the ordered `versions` list to preserve attachment order.
        Map<Id, Id> docByVersion = new Map<Id, Id>();
        for (ContentVersion cv : [
            SELECT Id, ContentDocumentId FROM ContentVersion WHERE Id IN :versionIds
        ]) {
            docByVersion.put(cv.Id, cv.ContentDocumentId);
        }

        List<StoredFile> stored = new List<StoredFile>();
        List<ContentDocumentLink> links = new List<ContentDocumentLink>();
        for (ContentVersion cv : versions) {
            Id docId = docByVersion.get(cv.Id);
            if (docId == null) {
                continue;
            }
            StoredFile sf = new StoredFile();
            sf.contentDocumentId = docId;
            sf.fileName = cv.Title;
            sf.isImage = isImageFile(cv.Title);
            stored.add(sf);
            links.add(new ContentDocumentLink(
                ContentDocumentId = docId,
                LinkedEntityId = caseId,
                ShareType = 'V',
                Visibility = 'AllUsers'
            ));
        }
        insert links;
        return stored;
    }

    /** True when the file name has a raster-image extension the vision model can read. */
    private Boolean isImageFile(String fileName) {
        if (String.isBlank(fileName)) {
            return false;
        }
        String f = fileName.toLowerCase();
        return f.endsWith('.png') || f.endsWith('.jpg') || f.endsWith('.jpeg')
            || f.endsWith('.gif') || f.endsWith('.bmp') || f.endsWith('.webp')
            || f.endsWith('.tif') || f.endsWith('.tiff') || f.endsWith('.heic');
    }

    /**
     * Returns the email body augmented with a plain-text rendering of any
     * spreadsheet (.xlsx/.xlsm) or delimited-text (.csv/.tsv) attachment, so the
     * prompt template can "read" the sheet through its existing description input.
     * The prompt template itself is untouched. Legacy .xls (binary BIFF) cannot be
     * parsed in Apex and is skipped with a debug log.
     */
    private String buildPromptDescription(Messaging.InboundEmail email, String baseDescription) {
        List<String> extras = new List<String>();

        if (email.binaryAttachments != null) {
            for (Messaging.InboundEmail.BinaryAttachment att : email.binaryAttachments) {
                String fn = att.fileName == null ? '' : att.fileName.toLowerCase();
                Integer bytes = att.body == null ? -1 : att.body.size();
                System.debug(LoggingLevel.INFO, 'SwiftParcel> binary attachment: "'
                    + att.fileName + '" mime=' + att.mimeTypeSubType + ' bytes=' + bytes);
                if (fn.endsWith('.xlsx') || fn.endsWith('.xlsm')) {
                    String txt = convertXlsxToText(att.body);
                    System.debug(LoggingLevel.INFO, 'SwiftParcel> xlsx "' + att.fileName
                        + '" -> text length=' + (txt == null ? 0 : txt.length())
                        + ' | preview=' + safePreview(txt, 500));
                    if (String.isNotBlank(txt)) {
                        extras.add('Spreadsheet "' + att.fileName + '" contents:\n' + txt);
                    }
                } else if (fn.endsWith('.xls')) {
                    System.debug(LoggingLevel.WARN,
                        'SwiftParcel> Legacy .xls not supported for text extraction: ' + att.fileName);
                }
            }
        }

        if (email.textAttachments != null) {
            for (Messaging.InboundEmail.TextAttachment att : email.textAttachments) {
                String fn = att.fileName == null ? '' : att.fileName.toLowerCase();
                if ((fn.endsWith('.csv') || fn.endsWith('.tsv')) && String.isNotBlank(att.body)) {
                    extras.add('Attached file "' + att.fileName + '" contents:\n' + att.body);
                }
            }
        }

        if (extras.isEmpty()) {
            return baseDescription;
        }
        return (String.isBlank(baseDescription) ? '' : baseDescription + '\n\n')
            + String.join(extras, '\n\n');
    }

    /**
     * Runs the prompt-template extraction and applies the results:
     *   - the first shipment updates the intake Case,
     *   - any further shipments become new Cases.
     * Returns every Case touched (intake first) so the acknowledgement can list
     * their numbers. If nothing is extracted the intake Case is returned as-is.
     */
    private List<Case> classifyAndPopulate(
        String subject,
        String description,
        String promptDescription,
        Id imageDocId,
        Case intakeCase,
        String fromAddress,
        List<Id> contentDocumentIds
    ) {
        // Extraction sees the augmented body (email + any spreadsheet text); the
        // plain `description` is still used for child Case Description fallbacks.
        List<ShipmentRecord> shipments = extractor.extract(subject, promptDescription, imageDocId);
        System.debug(LoggingLevel.INFO, 'SwiftParcel> extractor returned '
            + (shipments == null ? 'null' : String.valueOf(shipments.size()) + ' shipment(s)')
            + ' (imageDocId=' + imageDocId + ')');

        List<Case> touched = new List<Case>{ intakeCase };
        if (shipments == null || shipments.isEmpty()) {
            return touched;
        }

        // Hard cap on records created from a single email. A large sheet can yield
        // far more rows than we want to fan out into Cases in a demo org, so only
        // the first MAX_SHIPMENTS are processed; the rest are logged and dropped.
        if (shipments.size() > MAX_SHIPMENTS) {
            System.debug(LoggingLevel.WARN, 'SwiftParcel> extractor returned ' + shipments.size()
                + ' shipments; capping at ' + MAX_SHIPMENTS
                + ' (' + (shipments.size() - MAX_SHIPMENTS) + ' dropped)');
            List<ShipmentRecord> capped = new List<ShipmentRecord>();
            for (Integer i = 0; i < MAX_SHIPMENTS; i++) {
                capped.add(shipments[i]);
            }
            shipments = capped;
        }

        // UC1: a single shipment enriches the intake Case in place; no child Cases.
        if (shipments.size() == 1) {
            enrichCase(intakeCase, shipments[0]);
            update intakeCase;
            return touched;
        }

        // UC2: the intake Case is the parent (the inbound request). Every shipment
        // row becomes a child Case linked to it via ParentId.
        // Resolve the Contact for each row's email (falling back to the sender) in a
        // single query, so each child can be attached to a matching Contact.
        Set<String> childEmails = new Set<String>();
        for (ShipmentRecord s : shipments) {
            String em = String.isNotBlank(s.email) ? s.email : fromAddress;
            if (String.isNotBlank(em)) {
                childEmails.add(em);
            }
        }
        Map<String, Id> contactByEmail = findContactIdsByEmail(childEmails);

        List<Case> childCases = new List<Case>();
        for (ShipmentRecord s : shipments) {
            String em = String.isNotBlank(s.email) ? s.email : fromAddress;
            childCases.add(new Case(
                ParentId = intakeCase.Id,
                Subject = buildSubject(s),
                Description = String.isNotBlank(s.description) ? s.description : description,
                // Origin intentionally left blank (not 'Email'): the org's
                // SDO_Service_Case_Creation flow only sends an auto-response for
                // Origin = 'Email', so blank Origin suppresses per-child emails.
                // The customer still gets the parent's single acknowledgement.
                Status = 'New',
                SuppliedName = String.isNotBlank(s.name) ? s.name : null,
                SuppliedPhone = String.isNotBlank(s.mobileNumber) ? s.mobileNumber : null,
                SuppliedEmail = String.isNotBlank(em) ? em : null,
                ContactId = String.isNotBlank(em) ? contactByEmail.get(em) : null,
                AWB_Number__c = String.isNotBlank(s.awbNumber) ? s.awbNumber : null
            ));
        }

        insert childCases;
        linkSourceFile(childCases, contentDocumentIds);
        touched.addAll(childCases);

        // Flag the intake Case as the parent now that it has shipment child Cases.
        intakeCase.Parent_Case__c = true;
        update intakeCase;

        return touched;
    }

    /**
     * Applies a single shipment's extracted values onto the intake Case, only
     * filling name/phone/AWB when present and backfilling email/description when
     * the Case does not already have them (used for the UC1 single-shipment path).
     */
    private void enrichCase(Case intakeCase, ShipmentRecord s) {
        if (String.isNotBlank(s.name)) {
            intakeCase.SuppliedName = s.name;
        }
        if (String.isNotBlank(s.mobileNumber)) {
            intakeCase.SuppliedPhone = s.mobileNumber;
        }
        if (String.isNotBlank(s.awbNumber)) {
            intakeCase.AWB_Number__c = s.awbNumber;
        }
        if (String.isBlank(intakeCase.SuppliedEmail) && String.isNotBlank(s.email)) {
            intakeCase.SuppliedEmail = s.email;
        }
        if (isBlankBody(intakeCase.Description) && String.isNotBlank(s.description)) {
            intakeCase.Description = s.description;
        }
    }

    /**
     * Finds the Id of a Contact whose Email matches the given address. If more than
     * one Contact shares the address, any one of them is returned. Returns null when
     * the address is blank or no Contact matches.
     */
    private Id findContactIdByEmail(String emailAddr) {
        if (String.isBlank(emailAddr)) {
            return null;
        }
        return findContactIdsByEmail(new Set<String>{ emailAddr }).get(emailAddr);
    }

    /**
     * Bulk variant: returns a map of email address -> a matching Contact Id (any one
     * per address when several share it). Emails with no matching Contact are absent
     * from the map.
     */
    private Map<String, Id> findContactIdsByEmail(Set<String> emails) {
        Map<String, Id> result = new Map<String, Id>();
        if (emails == null || emails.isEmpty()) {
            return result;
        }
        for (Contact c : [SELECT Id, Email FROM Contact WHERE Email IN :emails]) {
            if (!result.containsKey(c.Email)) {
                result.put(c.Email, c.Id); // keep the first match; "any one" is fine
            }
        }
        return result;
    }

    /** Links the original source file(s) to each newly created Case for traceability. */
    private void linkSourceFile(List<Case> cases, List<Id> contentDocumentIds) {
        if (contentDocumentIds == null || contentDocumentIds.isEmpty()) {
            return;
        }
        List<ContentDocumentLink> links = new List<ContentDocumentLink>();
        for (Case c : cases) {
            for (Id docId : contentDocumentIds) {
                links.add(new ContentDocumentLink(
                    ContentDocumentId = docId,
                    LinkedEntityId = c.Id,
                    ShareType = 'V',
                    Visibility = 'AllUsers'
                ));
            }
        }
        insert links;
    }

    private String buildSubject(ShipmentRecord s) {
        String awb = String.isNotBlank(s.awbNumber) ? s.awbNumber : 'Unknown';
        String suffix = String.isNotBlank(s.description) ? ' - ' + s.description : '';
        return ('Shipment ' + awb + suffix).abbreviate(255);
    }

    private Boolean isBlankBody(String body) {
        return String.isBlank(body) || body == DEFAULT_BODY;
    }

    /**
     * Sends an acknowledgement email back to the original sender listing the
     * Case number(s) created and any AWB / shipment numbers recognised.
     */
    private void sendAcknowledgement(Messaging.InboundEmail email, List<Case> touched) {
        if (String.isBlank(email.fromAddress)) {
            return;
        }

        // Re-query for CaseNumber (populated after insert), the AWB and ParentId so we
        // can distinguish the parent (inbound request) Case from its shipment children.
        Set<Id> caseIds = new Set<Id>();
        for (Case c : touched) {
            caseIds.add(c.Id);
        }
        List<Case> withNumbers = [
            SELECT CaseNumber, AWB_Number__c, ParentId FROM Case WHERE Id IN :caseIds ORDER BY CaseNumber
        ];

        Case parentCase;
        List<Case> childCases = new List<Case>();
        for (Case c : withNumbers) {
            if (c.ParentId == null) {
                parentCase = c;
            } else {
                childCases.add(c);
            }
        }

        String body;
        if (!childCases.isEmpty()) {
            // UC2: one parent request Case with a child Case per shipment.
            String childLines = '';
            for (Case c : childCases) {
                childLines += '  - Case ' + c.CaseNumber
                    + (String.isNotBlank(c.AWB_Number__c) ? ' (AWB: ' + c.AWB_Number__c + ')' : '')
                    + '\n';
            }
            body =
                'Hello,\n\n' +
                'Thank you for contacting SwiftParcel. We have logged your request as reference Case '
                    + (parentCase != null ? parentCase.CaseNumber : '') + ' and created '
                    + childCases.size() + ' linked shipment cases:\n\n' +
                childLines + '\n' +
                'Our team will review the details and get back to you shortly.\n\n' +
                'Best regards,\n' +
                'SwiftParcel Customer Support Team';
        } else {
            // UC1 / no extraction: a single Case.
            Case only = parentCase != null ? parentCase : (withNumbers.isEmpty() ? null : withNumbers[0]);
            String line = only == null ? '' :
                '  - Case ' + only.CaseNumber
                + (String.isNotBlank(only.AWB_Number__c) ? ' (AWB: ' + only.AWB_Number__c + ')' : '')
                + '\n';
            body =
                'Hello,\n\n' +
                'Thank you for contacting SwiftParcel. We have logged the following case for your request:\n\n' +
                line + '\n' +
                'Our team will review the details and get back to you shortly.\n\n' +
                'Best regards,\n' +
                'SwiftParcel Customer Support Team';
        }

        Messaging.SingleEmailMessage reply = new Messaging.SingleEmailMessage();
        reply.setToAddresses(new List<String>{ email.fromAddress });
        reply.setSubject('Thank you - we have received your request');
        reply.setPlainTextBody(body);

        Messaging.sendEmail(new List<Messaging.SingleEmailMessage>{ reply });
    }

    /**
     * Default extractor: invokes the SwiftParcel_Shipment_Extraction Flex prompt template,
     * passing the subject, description and the attached image (as a ContentDocument
     * reference), and parses the JSON array the template returns.
     */
    public class PromptShipmentExtractor implements ShipmentExtractor {
        public List<ShipmentRecord> extract(String subject, String description, Id contentDocumentId) {
            ConnectApi.EinsteinPromptTemplateGenerationsInput input =
                new ConnectApi.EinsteinPromptTemplateGenerationsInput();

            Map<String, ConnectApi.WrappedValue> params = new Map<String, ConnectApi.WrappedValue>();
            params.put('Input:subject', wrap(subject == null ? '' : subject));
            params.put('Input:description', wrap(description == null ? '' : description));
            if (contentDocumentId != null) {
                // A ContentDocument input must be passed as a record reference map,
                // not a bare id string, for the image to be attached to the model.
                params.put('Input:File', wrap(new Map<String, Object>{ 'id' => contentDocumentId }));
            }
            input.inputParams = params;

            input.additionalConfig = new ConnectApi.EinsteinLlmAdditionalConfigInput();
            input.additionalConfig.numGenerations = 1;
            input.additionalConfig.enablePiiMasking = false;
            input.isPreview = false;

            ConnectApi.EinsteinPromptTemplateGenerationsRepresentation output =
                ConnectApi.EinsteinLLM.generateMessagesForPromptTemplate(TEMPLATE_NAME, input);

            if (output == null || output.generations == null || output.generations.isEmpty()) {
                System.debug(LoggingLevel.WARN, 'SwiftParcel> prompt template returned no generations');
                return new List<ShipmentRecord>();
            }
            String raw = output.generations[0].text;
            System.debug(LoggingLevel.INFO, 'SwiftParcel> raw model output (length='
                + (raw == null ? 0 : raw.length()) + '):\n' + raw);
            return parseShipments(raw);
        }

        private ConnectApi.WrappedValue wrap(Object value) {
            ConnectApi.WrappedValue w = new ConnectApi.WrappedValue();
            w.value = value;
            return w;
        }
    }

    /**
     * Parses the prompt template's response into ShipmentRecords. Tolerates code
     * fences and surrounding prose by extracting the outermost JSON array.
     */
    @TestVisible
    private static List<ShipmentRecord> parseShipments(String rawText) {
        if (String.isBlank(rawText)) {
            return new List<ShipmentRecord>();
        }
        String payload = rawText.trim();
        Integer start = payload.indexOf('[');
        Integer endIdx = payload.lastIndexOf(']');
        if (start == -1 || endIdx == -1 || endIdx < start) {
            return new List<ShipmentRecord>();
        }
        payload = payload.substring(start, endIdx + 1);
        try {
            return (List<ShipmentRecord>) JSON.deserialize(payload, List<ShipmentRecord>.class);
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'Failed to parse shipment JSON: ' + e.getMessage()
                + ' | raw: ' + rawText);
            return new List<ShipmentRecord>();
        }
    }

    // ------------------------------------------------------------------
    // XLSX -> text
    //
    // An .xlsx file is a ZIP of XML parts. We unzip it in-memory with the
    // Compression API, read the shared-strings table and each worksheet, and
    // reconstruct the rows as tab/newline-delimited text. This gives the vision
    // prompt a readable rendering of the sheet without touching the template.
    // Caveats: cells are emitted in document order (empty gaps are not padded),
    // dates surface as their numeric serial, and formatting is dropped - fine
    // for extracting names / mobiles / AWBs.
    // ------------------------------------------------------------------

    @TestVisible
    private static String convertXlsxToText(Blob xlsx) {
        if (xlsx == null) {
            return '';
        }
        try {
            Compression.ZipReader reader = new Compression.ZipReader(xlsx);
            Blob sharedBlob = null;
            Map<String, Blob> sheetBlobs = new Map<String, Blob>();
            List<String> allEntryNames = new List<String>();
            for (Compression.ZipEntry entry : reader.getEntries()) {
                String name = entry.getName();
                allEntryNames.add(name);
                if (name == 'xl/sharedStrings.xml') {
                    sharedBlob = entry.getContent();
                } else if (name.startsWith('xl/worksheets/') && name.endsWith('.xml')) {
                    sheetBlobs.put(name, entry.getContent());
                }
            }
            System.debug(LoggingLevel.INFO, 'SwiftParcel> zip entries (' + allEntryNames.size()
                + '): ' + allEntryNames);
            System.debug(LoggingLevel.INFO, 'SwiftParcel> sharedStrings found=' + (sharedBlob != null)
                + ' | worksheet parts=' + sheetBlobs.keySet());

            List<String> shared = parseSharedStrings(sharedBlob);
            List<String> sheetNames = new List<String>(sheetBlobs.keySet());
            sheetNames.sort();

            List<String> parts = new List<String>();
            for (String sn : sheetNames) {
                String txt = parseSheet(sheetBlobs.get(sn), shared);
                System.debug(LoggingLevel.INFO, 'SwiftParcel> sheet "' + sn + '" rows-text length='
                    + (txt == null ? 0 : txt.length()));
                if (String.isNotBlank(txt)) {
                    parts.add(txt);
                }
            }
            System.debug(LoggingLevel.INFO, 'SwiftParcel> sharedStrings count=' + shared.size());
            return String.join(parts, '\n');
        } catch (Exception ex) {
            System.debug(LoggingLevel.ERROR, 'SwiftParcel> xlsx parse FAILED: ' + ex.getTypeName()
                + ': ' + ex.getMessage() + '\n' + ex.getStackTraceString());
            return '';
        }
    }

    /** Parses xl/sharedStrings.xml into an ordered list of strings (index = string id). */
    private static List<String> parseSharedStrings(Blob xml) {
        List<String> strings = new List<String>();
        if (xml == null) {
            return strings;
        }
        Dom.Document doc = new Dom.Document();
        doc.load(xml.toString());
        for (Dom.XmlNode si : doc.getRootElement().getChildElements()) {
            if (si.getName() == 'si') {
                strings.add(gatherText(si));
            }
        }
        return strings;
    }

    /** Renders one worksheet's rows as tab-delimited lines. */
    private static String parseSheet(Blob xml, List<String> shared) {
        if (xml == null) {
            return '';
        }
        Dom.Document doc = new Dom.Document();
        doc.load(xml.toString());
        Dom.XmlNode sheetData = getChild(doc.getRootElement(), 'sheetData');
        if (sheetData == null) {
            return '';
        }
        List<String> lines = new List<String>();
        for (Dom.XmlNode row : sheetData.getChildElements()) {
            if (row.getName() != 'row') {
                continue;
            }
            List<String> cells = new List<String>();
            for (Dom.XmlNode c : row.getChildElements()) {
                if (c.getName() == 'c') {
                    cells.add(cellValue(c, shared));
                }
            }
            lines.add(String.join(cells, '\t'));
        }
        return String.join(lines, '\n');
    }

    /** Resolves a single cell's display value (shared string, inline string, or literal). */
    private static String cellValue(Dom.XmlNode c, List<String> shared) {
        String t = c.getAttributeValue('t', null);
        if (t == 'inlineStr') {
            Dom.XmlNode isNode = getChild(c, 'is');
            return isNode == null ? '' : gatherText(isNode);
        }
        Dom.XmlNode v = getChild(c, 'v');
        if (v == null) {
            return '';
        }
        String raw = v.getText();
        if (t == 's') {
            try {
                Integer idx = Integer.valueOf(raw);
                return (idx >= 0 && idx < shared.size()) ? shared[idx] : '';
            } catch (Exception e) {
                return '';
            }
        }
        return raw;
    }

    /** Concatenates every descendant <t> text node (handles rich-text runs). */
    private static String gatherText(Dom.XmlNode node) {
        String result = '';
        for (Dom.XmlNode child : node.getChildElements()) {
            if (child.getName() == 't') {
                String txt = child.getText();
                if (txt != null) {
                    result += txt;
                }
            } else {
                result += gatherText(child);
            }
        }
        return result;
    }

    /** Truncated, debug-safe preview of a possibly-long / null string. */
    private static String safePreview(String s, Integer max) {
        if (s == null) {
            return '(null)';
        }
        return s.length() <= max ? s : s.substring(0, max) + '...[' + s.length() + ' chars]';
    }

    /** First direct child element with the given (namespace-agnostic) local name, or null. */
    private static Dom.XmlNode getChild(Dom.XmlNode parent, String localName) {
        for (Dom.XmlNode ch : parent.getChildElements()) {
            if (ch.getName() == localName) {
                return ch;
            }
        }
        return null;
    }
}
